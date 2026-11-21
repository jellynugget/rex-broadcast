#!/bin/sh
# Install rex-broadcast into Rex's config folder.
#
#   ./install.sh             link the files and load them
#   ./install.sh --uninstall remove them again
#
# The files are symlinked, not copied, so edits in this repo take effect after
# `rex config reload`.
set -eu

REPO="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rex"
INIT="$CONFIG_DIR/init.lua"
REQUIRE='require("broadcast")'
FILES="broadcast.lua"
# Files older versions installed; removed if they are links into this repo.
OLD_FILES="broadcast-banner.sh"

find_rex() {
  if command -v rex >/dev/null 2>&1; then command -v rex; return; fi
  app="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
  if [ -x "$app" ]; then echo "$app"; return; fi
  echo ""
}

reload() {
  rex_bin="$(find_rex)"
  if [ -z "$rex_bin" ]; then
    echo "Could not find the rex command. Run 'rex config reload' yourself."
    return
  fi
  "$rex_bin" config check "$INIT"
  "$rex_bin" config reload
}

if [ "${1:-}" = "--uninstall" ]; then
  for f in $FILES $OLD_FILES; do
    if [ -L "$CONFIG_DIR/$f" ]; then rm "$CONFIG_DIR/$f"; echo "removed $CONFIG_DIR/$f"; fi
  done
  rm -f "$CONFIG_DIR/.broadcast-state.json"
  if [ -f "$INIT" ] && grep -qxF "$REQUIRE" "$INIT"; then
    grep -vxF "$REQUIRE" "$INIT" > "$INIT.tmp" && mv "$INIT.tmp" "$INIT"
    echo "removed $REQUIRE from $INIT"
  fi
  reload
  exit 0
fi

mkdir -p "$CONFIG_DIR"

for f in $OLD_FILES; do
  if [ -L "$CONFIG_DIR/$f" ]; then rm "$CONFIG_DIR/$f"; echo "removed old $CONFIG_DIR/$f"; fi
done

for f in $FILES; do
  target="$CONFIG_DIR/$f"
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    mv "$target" "$target.bak"
    echo "backed up existing $target to $target.bak"
  fi
  ln -sfn "$REPO/$f" "$target"
  echo "linked $target -> $REPO/$f"
done

if [ ! -f "$INIT" ] || ! grep -qxF "$REQUIRE" "$INIT"; then
  echo "$REQUIRE" >> "$INIT"
  echo "added $REQUIRE to $INIT"
fi

reload
echo "Done. Press cmd+shift+i in Rex to start broadcasting."
