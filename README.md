# rex-broadcast

[![test](https://github.com/jellynugget/rex-broadcast/actions/workflows/test.yml/badge.svg)](https://github.com/jellynugget/rex-broadcast/actions/workflows/test.yml)

Broadcast input for [Rex](https://www.superlogical.com/rex), the terminal from
Superlogical: type once, and every terminal pane in the current tab gets the
same keys. It is like `synchronize-panes` in tmux or Broadcast Input in iTerm2.

![Typing once into three panes with rex-broadcast](docs/demo.gif)

It is a Rex config module (Lua), not a separate program.

## Use

| Key | What it does |
|---|---|
| `cmd+shift+i` | Start broadcasting in this tab. Each pane shows **((•)) Broadcasting · Esc to stop** after its name in the header. |
| `cmd+shift+i` again, or `Escape` | Stop broadcasting. The headers go back to normal. |

Broadcasting belongs to the tab where you started it. Switch to another tab
and your keys go to the focused pane as usual; switch back and they are
broadcast again. Pressing `cmd+shift+i` in another tab moves broadcasting
there.

While broadcasting, the keys below go to every pane. Other keys, such as
`cmd` shortcuts, work as usual.

- Letters, with `shift` and `ctrl`
- Digits and punctuation, with `shift` (US keyboard layout)
- `space`, `enter`, `tab`, `shift+tab`, `backspace`, `alt+backspace`, `delete`
- Arrow keys, `home`, `end`, `pageup`, `pagedown`

The command palette also has **Broadcast: Start**, **Stop** and **Toggle
Typing in All Panes** (actions `broadcast_on`, `broadcast_off` and
`broadcast_toggle`).

## Install

Requires Rex for macOS.

```sh
git clone https://github.com/jellynugget/rex-broadcast ~/github/rex-broadcast
cd ~/github/rex-broadcast
./install.sh
```

`install.sh` symlinks `broadcast.lua` into Rex's config folder
(`~/.config/rex`, or `$XDG_CONFIG_HOME/rex`), adds
`require("broadcast").setup()` to `init.lua`, and reloads Rex. An existing
`broadcast.lua` that isn't a link is moved to `broadcast.lua.bak` first.
If `init.lua` has the line older versions added, `require("broadcast")`, it
is replaced.

To install by hand, copy `broadcast.lua` into Rex's config folder, add
`require("broadcast").setup()` to `init.lua`, and run `rex config reload`.

To update, run `git pull`, then `rex config reload`.

To remove it:

```sh
./install.sh --uninstall
```

This removes the link, the state file, and any one-line
`require("broadcast")...` from `init.lua`. If you spread the `setup` call over
several lines, it tells you to remove that by hand.

## Options

Pass options to `setup` in `init.lua`. All are optional.

```lua
require("broadcast").setup{
  key = "cmd+shift+i",  -- starts and stops broadcasting
  stop_key = "escape",  -- also stops it; false to send Escape to the panes
}
```

With `stop_key = false`, `Escape` is broadcast like any other key, which you
need for programs such as vim, and the header shows only **Broadcasting**.
An option of the wrong type, or an unknown option, is ignored and logged.

## How it works

- **No key mode.** Rex has key modes, but it shows a pop-up listing every key
  of an active mode, and no setting hides it. So instead each typing key is
  bound with `rex.bind(key, function)`. While broadcasting is off, the function
  returns `false` at once, and Rex sends the key to the focused pane as usual.
- **State.** A Lua variable holds the session and tab being broadcast to,
  and the panes' original labels. It is also saved to
  `.broadcast-state.json` in Rex's config folder, so reloading the config
  keeps broadcasting on and never loses the labels to put back. A state file
  that can't be read is ignored. State left over from before a server
  restart doesn't match any tab, so keys aren't broadcast, and the next
  `cmd+shift+i` starts broadcasting in the current tab.
- **Fan-out.** While broadcasting, the function reads the session view and
  writes the key's bytes (for example `\27[A` for up) to every terminal block
  in the tab with the terminal's `write` method. A pane that fails, such as
  one closed a moment ago, is skipped and logged.
- **Header mark.** Rex has no way for a config to add an icon next to the pane
  header buttons, so the mark goes in each pane's label. Starting sets the
  label to the name Rex normally shows (program and folder), then the SF
  Symbol `dot.radiowaves.left.and.right` and "Broadcasting · Esc to stop".
  The symbol is the private-use character U+100319, which macOS draws as an
  icon in the system font. Labels are plain text, so there is no color or
  background. A long name is shortened with "…" to fit Rex's 128-character
  label limit. Stopping puts the original label back. A pane opened while
  broadcasting gets the mark on the next key you type.

## Limits

- Paste, input methods (such as emoji or CJK input), and the mouse are not
  mirrored.
- Punctuation assumes a US keyboard layout.
- With the default `stop_key`, `Escape` stops broadcasting, so it can't be
  sent to the panes. Set `stop_key = false` to send it.
- Every bound key passes through a Lua function, even while broadcasting is
  off, which adds a round trip to the Rex server for each key. It was not
  noticeable in testing. If typing ever feels slow, remove the
  `require("broadcast")` line from `init.lua`.
- Very fast input (dozens of keys within a few milliseconds, as from a script)
  can drop or reorder keys. Normal typing is fine.
- While broadcasting, a pane's header doesn't follow `cd` or a new program;
  it shows the name from when broadcasting started.
- In a narrow pane, Rex cuts the end of the header off, so the note (or the
  icon) may be hidden.
- The icon is an Apple SF Symbol character. It only draws on Apple platforms,
  and Apple could move it to another code point in a later macOS. If it shows
  as a box, change `ICON` in `broadcast.lua`.

## Development

```sh
bash test/run.sh   # unit tests with a fake rex, plus shellcheck; what CI runs
bash test/e2e.sh   # end-to-end, against your running Rex
```

- `test/broadcast_test.lua` runs `broadcast.lua` under LuaJIT against
  `test/fake_rex.lua`, an in-memory stand-in for the `rex` global with
  sessions, tabs and panes. It covers the edge cases: keys passing through
  while off, other tabs and sessions, panes opened or closed while
  broadcasting, a pane that fails to write, a rex that raises instead of
  returning errors, config reloads, broken state files, state left from before
  a server restart, bad options, and shortening long or multibyte names.
- `test/e2e.sh` needs Rex running with this module installed. It makes a
  throwaway session with three panes, presses keys with `rex send-key` (which
  runs the Lua key bindings like a real key press), checks each pane's screen
  with `rex capture`, and kills the session. It also checks label shortening
  in Rex's own Lua, which is not LuaJIT. The Rex app keeps showing what it
  showed before.
- `scripts/record-demo.sh` records `docs/demo.gif`. It takes over the Rex
  window for about 20 seconds; see the comment at its top.

## License

[MIT](LICENSE)
