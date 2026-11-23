#!/usr/bin/env bash
# Record docs/demo.gif: broadcasting in a throwaway three-pane session.
#
#   bash scripts/record-demo.sh
#
# Takes over the Rex window for about 20 seconds, so don't use Rex while it
# runs. It:
#   1. makes a session "broadcast-demo-<pid>" with three panes running
#      `zsh -f`, labeled server-1 to server-3, so no shell plugins, history,
#      user name or host name show up;
#   2. adds a temporary action to init.lua that switches the app to it, since
#      the CLI can only switch the app's session with Remote Control on;
#   3. brings Rex to the front (macOS stops drawing a covered window's
#      terminals), hides the sidebar so your other sessions aren't recorded,
#      and makes the window smaller;
#   4. presses keys with `rex send-key` while taking screenshots;
#   5. puts everything back, closing only the tab it made, then builds the
#      GIF, with a caption showing each ⇧⌘I press, and asks you to check it.
#
# Needs macOS, ffmpeg, swift (Xcode command line tools), broadcast.lua
# installed with the default keys, and Accessibility access for your terminal
# (System Settings > Privacy & Security) to resize the window.

set -uo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/docs/demo.gif"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/rex"
init="$config_dir/init.lua"
state_file="$config_dir/.broadcast-state.json"
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
[[ -e $state_file ]] && { echo "Broadcasting is on in some tab. Turn it off first."; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/rex-broadcast-demo.XXXXXX")
session=""      # the demo session
window=""       # the demo tab, the only one this script closes
first_block=""
old_size=""
old_app=""      # the app that was in front before
sidebar_hidden=0
recorder=""
restored=0

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

session_view() { "$rex" api call session.view "{\"session_id\":\"$session\"}" 2>/dev/null; }

# Put everything back. Safe to run twice. Closes only the demo tab, and the
# demo session only if nothing else was opened in it meanwhile.
restore() {
  [[ $restored -eq 1 ]] && return
  restored=1
  echo "restoring"
  if [[ -n $recorder ]]; then touch "$work/stop"; wait "$recorder" 2>/dev/null; recorder=""; fi
  # Stop broadcasting only if it is the demo tab's.
  if [[ -n $window ]] && grep -qF "$window" "$state_file" 2>/dev/null; then perform broadcast_off; fi
  if [[ $sidebar_hidden -eq 1 ]]; then perform zz_demo_sidebar; sidebar_hidden=0; fi
  if [[ -n $old_size ]]; then window_size "${old_size%,*}" "${old_size#*,}"; fi
  if [[ -n $session ]]; then
    perform zz_demo_back
    sleep 0.5
    if [[ -n $window ]]; then
      "$rex" api call session.close_window "{\"session_id\":\"$session\",\"window_id\":\"$window\"}" >/dev/null 2>&1
    fi
    if session_view | grep -q '"window_id"'; then
      echo "left session $session open: something else was opened in it"
    else
      "$rex" kill "$session" >/dev/null 2>&1
    fi
  fi
  if [[ -f $init ]] && grep -qxF "$helper_line" "$init"; then
    { grep -vxF "$helper_line" "$init" || true; } > "$init.tmp" && mv "$init.tmp" "$init"
  fi
  rm -f "$helper"
  "$rex" config reload >/dev/null 2>&1
  if [[ -n $old_app ]]; then osascript -e "tell application id \"$old_app\" to activate" >/dev/null 2>&1; fi
}
cleanup() { restore; rm -rf "$work"; }
trap cleanup EXIT

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
# zsh -f reads no startup files: no plugins such as autosuggestions showing
# your shell history, and no history file.
json=$("$rex" new "broadcast-demo-$$" --json -c "$HOME" -- zsh -f) || exit 1
session=$(printf '%s\n' "$json" | sed -n 's/.*"session_id": *"\([^"]*\)".*/\1/p' | head -1)
window=$(printf '%s\n' "$json" | sed -n 's/.*"window_id": *"\([^"]*\)".*/\1/p' | head -1)
[[ -n $session && -n $window ]] || { echo "could not read the new session"; exit 1; }
"$rex" split -s "$session" --focus=false -- zsh -f >/dev/null
"$rex" split -s "$session" --split=below --focus=false -- zsh -f >/dev/null

# Set a prompt without the host name, go to ~, clear the screen, and label
# the panes server-1..3.
n=0
for b in $(session_view | grep -o '"block_id": *"block:[^"]*"' |
           sed 's/.*"\(block:[^"]*\)"/\1/' | awk '!seen[$0]++'); do
  n=$((n + 1))
  [[ -z $first_block ]] && first_block=$b
  "$rex" send -b "$b" $'PROMPT=\'%F{cyan}%~%f %F{green}$%f \'; cd ~; clear\r' >/dev/null
  "$rex" api call session.set_block_label \
    "{\"session_id\":\"$session\",\"block_id\":\"$b\",\"label\":\"server-$n\"}" >/dev/null
done
[[ $n -eq 3 ]] || { echo "expected 3 panes, found $n"; exit 1; }

echo "showing it in Rex"
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
old_app=$(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true' 2>/dev/null)
old_size=$(window_size)
osascript -e "tell application id \"$bundle\" to activate" >/dev/null 2>&1
perform zz_demo_show
perform zz_demo_sidebar && sidebar_hidden=1
window_size 900 520
sleep 1.5

wid=$(window_id)
[[ -n $wid && $wid != 0 ]] || { echo "could not find the Rex window"; exit 1; }

echo "recording"
mkdir -p "$work/frames"
(
  i=0
  while [[ ! -e $work/stop ]]; do
    i=$((i + 1))
    screencapture -l "$wid" -x -o "$(printf '%s/frames/%05d.png' "$work" "$i")"
    sleep 0.05
  done
) &
recorder=$!
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
started=$(now)

key() { "$rex" send-key -s "$session" "$1" >/dev/null; }
keys() {  # keys TEXT: type TEXT one key at a time
  local text=$1 i ch
  for (( i = 0; i < ${#text}; i++ )); do
    ch=${text:i:1}
    [[ $ch == " " ]] && ch=space
    key "$ch"
    sleep 0.06
  done
}

# Seconds into the recording of each cmd+shift+i press, for the captions.
since() { awk -v a="$started" -v b="$(now)" 'BEGIN { printf "%.2f", b - a }'; }

sleep 1.2
t_start=$(since); key cmd+shift+i; sleep 1.5
keys "echo hello from every pane"; key enter; sleep 1.2
keys "tty"; key enter; sleep 1.8
t_stop=$(since); key cmd+shift+i; sleep 1.2
keys "echo just this one"; key enter; sleep 2.5

touch "$work/stop"; wait "$recorder"; recorder=""
ended=$(now)
# Check the keys reached the panes before giving the demo panes back.
typed=$("$rex" capture -b "$first_block" --trim 2>/dev/null | grep -c 'hello from every pane')
restore

frames=$(find "$work/frames" -name '*.png' | wc -l | tr -d ' ')
fps=$(awk -v n="$frames" -v a="$started" -v b="$ended" 'BEGIN { r = n / (b - a); printf "%.2f", (r > 0 ? r : 8) }')
echo "captured $frames frames at $fps fps"
if [[ $typed -eq 0 ]]; then
  echo "The typed text never reached the panes, so the GIF would be blank. Not writing it."
  exit 1
fi

# Draw the key captions with AppKit (Homebrew's ffmpeg has no drawtext).
caption() {  # caption KEY TEXT SIZE OUT.png
  swift - "$@" <<'EOF'
import AppKit
let a = CommandLine.arguments
let key = a[1], text = a[2], size = CGFloat(Double(a[3])!), out = a[4]
let keyStr = NSAttributedString(string: key, attributes: [
  .font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: NSColor.black])
let textStr = NSAttributedString(string: text, attributes: [
  .font: NSFont.systemFont(ofSize: size * 0.8, weight: .medium), .foregroundColor: NSColor.white])
let ks = keyStr.size(), ts = textStr.size()
let pad = size * 0.45, capPadX = size * 0.4, capPadY = size * 0.12, gap = size * 0.5
let capW = ks.width + 2 * capPadX, capH = ks.height + 2 * capPadY
let w = ceil(pad + capW + gap + ts.width + pad * 1.4), h = ceil(capH + 2 * pad)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h),
  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(white: 0.08, alpha: 0.88).setFill()
NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h), xRadius: h * 0.3, yRadius: h * 0.3).fill()
NSColor(white: 0.95, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: pad, y: pad, width: capW, height: capH),
  xRadius: size * 0.25, yRadius: size * 0.25).fill()
keyStr.draw(at: NSPoint(x: pad + capPadX, y: pad + capPadY))
textStr.draw(at: NSPoint(x: pad + capW + gap, y: (h - ts.height) / 2))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
EOF
}
width=$(sips -g pixelWidth "$work/frames/00001.png" | awk '/pixelWidth/ { print $2 }')
size=$(awk -v w="$width" 'BEGIN { printf "%.0f", w * 0.027 }')
caption "⇧⌘I" "Start broadcasting" "$size" "$work/start.png" &&
  caption "⇧⌘I" "Stop broadcasting" "$size" "$work/stop.png" || exit 1
# Each caption shows from its key press for 1.6 seconds, at the bottom.
at='x=(W-w)/2:y=H-h-H*0.05'
show() { awk -v t="$1" 'BEGIN { printf "between(t,%.2f,%.2f)", t, t + 1.6 }'; }

mkdir -p "$(dirname "$out")"
ffmpeg -loglevel error -y -framerate "$fps" -i "$work/frames/%05d.png" \
  -i "$work/start.png" -i "$work/stop.png" -filter_complex \
  "[0:v][1:v]overlay=$at:enable='$(show "$t_start")'[v1];[v1][2:v]overlay=$at:enable='$(show "$t_stop")',fps=10,scale=800:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=none" \
  "$out" || exit 1
echo "wrote $out ($(du -h "$out" | cut -f1))"

# The GIF goes in a public README, so have a person look at it.
open -a Preview "$out" 2>/dev/null
echo
echo "The GIF just opened in Preview. It will be public on GitHub, so check that"
echo "it shows only the three demo panes typing: no sidebar, other sessions,"
echo "or anything personal."
read -r -p "Keep it? [y/N] " answer
if [[ $answer != [yY]* ]]; then rm -f "$out"; echo "deleted $out"; fi
