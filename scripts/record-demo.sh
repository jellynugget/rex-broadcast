#!/usr/bin/env bash
# Record docs/demo.gif: broadcasting in a throwaway three-pane session.
#
#   bash scripts/record-demo.sh
#
# Takes over the Rex window for about 20 seconds, so don't use Rex while it
# runs. It:
#   1. makes a session "broadcast-demo" with three panes in ~, labeled
#      server-1 to server-3 (so headers don't show your user or host name);
#   2. adds a temporary action to init.lua that switches the app to it, since
#      the CLI can only switch the app's session with Remote Control on;
#   3. hides the sidebar, so your other sessions aren't recorded, and makes
#      the window smaller;
#   4. presses keys with `rex send-key` while taking screenshots;
#   5. puts everything back, even if it fails part way, and builds the GIF.
#
# Needs macOS, ffmpeg, swift (Xcode command line tools), broadcast.lua
# installed with the default keys, and Accessibility access for your terminal
# (System Settings > Privacy & Security) to resize the window. Look at the GIF
# before you publish it.

set -uo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/docs/demo.gif"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/rex"
init="$config_dir/init.lua"
helper="$config_dir/.rex-broadcast-demo.lua"
helper_line="pcall(dofile, \"$helper\")  -- rex-broadcast demo; safe to delete"
bundle="com.superlogical.rex"

rex=$(command -v rex || true)
app_rex="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
if [[ -z $rex && -x $app_rex ]]; then rex=$app_rex; fi
for need in ffmpeg swift osascript screencapture; do
  command -v "$need" >/dev/null || { echo "needs $need"; exit 1; }
done
[[ -n $rex ]] || { echo "needs the rex command"; exit 1; }
[[ -e "$config_dir/.broadcast-state.json" ]] && { echo "Turn broadcasting off first."; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/rex-broadcast-demo.XXXXXX")
session=""
old_size=""
sidebar_hidden=0

perform() {  # perform ACTION: run a config action in the Rex app
  osascript -e "tell application id \"$bundle\" to perform \"$1\"" >/dev/null 2>&1
}

window_size() {  # window_size [W H]: print, or set, the main window's size
  local target='(first window whose name is not "")'
  local proc="(first process whose bundle identifier is \"$bundle\")"
  if [[ $# -eq 2 ]]; then
    osascript -e "tell application \"System Events\" to tell $proc to set size of $target to {$1, $2}" >/dev/null 2>&1
  else
    osascript -e "tell application \"System Events\" to tell $proc to get size of $target" 2>/dev/null | tr -d ' '
  fi
}

recorder=""

restore() {
  echo "restoring"
  if [[ -n $recorder ]]; then touch "$work/stop"; wait "$recorder" 2>/dev/null; fi
  if [[ -n $session ]]; then "$rex" send-key -s "$session" escape >/dev/null 2>&1; fi
  if [[ $sidebar_hidden -eq 1 ]]; then perform zz_demo_sidebar; fi
  if [[ -n $old_size ]]; then window_size "${old_size%,*}" "${old_size#*,}"; fi
  if [[ -n $session ]]; then perform zz_demo_back; sleep 0.5; "$rex" kill "$session" >/dev/null 2>&1; fi
  if [[ -f $init ]] && grep -qxF "$helper_line" "$init"; then
    { grep -vxF "$helper_line" "$init" || true; } > "$init.tmp" && mv "$init.tmp" "$init"
  fi
  rm -f "$helper"
  "$rex" config reload >/dev/null 2>&1
  rm -rf "$work"
}
trap restore EXIT

# The CGWindowID of Rex's largest on-screen window, for screencapture -l.
window_id() {
  swift - <<'EOF' 2>/dev/null
import AppKit
let pids = NSRunningApplication.runningApplications(withBundleIdentifier: "com.superlogical.rex").map { $0.processIdentifier }
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var best: (Int, Int) = (0, 0)
for w in list {
  guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
        (w[kCGWindowLayer as String] as? Int) == 0,
        let b = w[kCGWindowBounds as String] as? [String: Double],
        let id = w[kCGWindowNumber as String] as? Int else { continue }
  let area = Int((b["Width"] ?? 0) * (b["Height"] ?? 0))
  if area > best.1 { best = (id, area) }
}
print(best.0)
EOF
}

echo "making the demo session"
json=$("$rex" new broadcast-demo --json -c "$HOME") || exit 1
session=$(printf '%s\n' "$json" | sed -n 's/.*"session_id": *"\([^"]*\)".*/\1/p' | head -1)
"$rex" split -s "$session" --focus=false >/dev/null
"$rex" split -s "$session" --split=below --focus=false >/dev/null
# Go to ~, clear the screen, and label the panes server-1..3.
n=0
for b in $("$rex" api call session.view "{\"session_id\":\"$session\"}" |
           grep -o '"block_id": *"block:[^"]*"' | sed 's/.*"\(block:[^"]*\)"/\1/' | awk '!seen[$0]++'); do
  n=$((n + 1))
  "$rex" send -b "$b" $'cd ~ && clear\r' >/dev/null
  "$rex" api call session.set_block_label \
    "{\"session_id\":\"$session\",\"block_id\":\"$b\",\"label\":\"server-$n\"}" >/dev/null
done
[[ $n -eq 3 ]] || { echo "expected 3 panes, found $n"; exit 1; }

echo "adding a temporary action to show it"
cat > "$helper" <<EOF
-- Temporary, made by rex-broadcast's scripts/record-demo.sh.
rex.action{ name = "zz_demo_show", title = "Demo: show session", run = function()
  rex.client.queue("session.select", { session_id = "$session" }) end }
rex.action{ name = "zz_demo_back", title = "Demo: go back", run = function()
  rex.client.queue("session.back", {}) end }
rex.action{ name = "zz_demo_sidebar", title = "Demo: toggle sidebar", run = function()
  rex.client.queue("client.sidebar.toggle", {}) end }
EOF
echo "$helper_line" >> "$init"
"$rex" config reload >/dev/null || exit 1
old_size=$(window_size)
perform zz_demo_show
perform zz_demo_sidebar && sidebar_hidden=1
window_size 900 520
sleep 1.5

wid=$(window_id)
[[ -n $wid && $wid != 0 ]] || { echo "could not find the Rex window"; exit 1; }

echo "recording"
mkdir -p "$work/frames"
(
  n=0
  while [[ ! -e $work/stop ]]; do
    n=$((n + 1))
    screencapture -l "$wid" -x -o "$(printf '%s/frames/%05d.png' "$work" "$n")"
    sleep 0.05
  done
) &
recorder=$!
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
started=$(now)

keys() {  # keys TEXT: type TEXT one key at a time
  local text=$1 i ch
  for (( i = 0; i < ${#text}; i++ )); do
    ch=${text:i:1}
    [[ $ch == " " ]] && ch=space
    "$rex" send-key -s "$session" "$ch" >/dev/null
    sleep 0.06
  done
}

sleep 1.2
"$rex" send-key -s "$session" cmd+shift+i >/dev/null; sleep 1.5
keys "echo hello from every pane"; "$rex" send-key -s "$session" enter >/dev/null; sleep 1.2
keys "tty"; "$rex" send-key -s "$session" enter >/dev/null; sleep 1.8
"$rex" send-key -s "$session" escape >/dev/null; sleep 1.2
keys "echo just this one"; "$rex" send-key -s "$session" enter >/dev/null; sleep 2.5

touch "$work/stop"; wait "$recorder"; recorder=""
ended=$(now)
frames=$(find "$work/frames" -name '*.png' | wc -l | tr -d ' ')
fps=$(awk -v n="$frames" -v a="$started" -v b="$ended" 'BEGIN { r = n / (b - a); printf "%.2f", (r > 0 ? r : 8) }')
echo "captured $frames frames at $fps fps"

mkdir -p "$(dirname "$out")"
ffmpeg -loglevel error -y -framerate "$fps" -i "$work/frames/%05d.png" \
  -vf "fps=12,scale=900:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=none" \
  "$out" || exit 1
echo "wrote $out ($(du -h "$out" | cut -f1))"
# The GIF is meant for a public README: check that it shows only the demo
# panes, not the sidebar or anything else from your screen.
open -a Preview "$out" 2>/dev/null
read -r -p "Does it show only the demo panes? Keep it? [y/N] " answer
if [[ $answer != [yY]* ]]; then rm -f "$out"; echo "deleted $out"; fi
