# rex-broadcast

Broadcast input for [Rex](https://www.superlogical.com/rex), the terminal from
Superlogical: type once, and every terminal pane in the current tab gets the
same keys. It is like `synchronize-panes` in tmux or Broadcast Input in iTerm2.

It is a Rex config module (Lua), not a separate program.

## Use

| Key | What it does |
|---|---|
| `cmd+shift+i` | Start broadcasting. Each pane in the tab shows **((•)) Broadcasting · Esc to stop** after its name in the header. |
| `cmd+shift+i` again, or `Escape` | Stop broadcasting. The headers go back to normal. |

Broadcasting belongs to the tab where you started it. Switch to another tab
and your keys go to the focused pane as usual; switch back and they are
broadcast again.

While broadcasting, the keys below go to every pane. Other keys, such as
`cmd` shortcuts, work as usual.

- Letters, with `shift` and `ctrl`
- Digits and punctuation, with `shift` (US keyboard layout)
- `space`, `enter`, `tab`, `shift+tab`, `backspace`, `alt+backspace`, `delete`
- Arrow keys, `home`, `end`, `pageup`, `pagedown`

## Install

Requires Rex for macOS.

```sh
git clone <this repo> ~/github/rex-broadcast
cd ~/github/rex-broadcast
./install.sh
```

`install.sh` symlinks `broadcast.lua` into Rex's config folder (`~/.config/rex`, or `$XDG_CONFIG_HOME/rex`), adds
`require("broadcast")` to `init.lua`, and reloads Rex. An existing file with
the same name is moved to `*.bak` first.

To remove it:

```sh
./install.sh --uninstall
```

After editing the files in this repo, run `rex config reload`.

## How it works

- **No key mode.** Rex has key modes, but it shows a pop-up listing every key
  of an active mode, and no setting hides it. So instead each typing key is
  bound with `rex.bind(key, function)`. While broadcasting is off, the function
  returns `false` at once, and Rex sends the key to the focused pane as usual.
- **State.** A Lua variable holds the session and tab being broadcast to,
  and the panes' original labels. It is also saved to
  `.broadcast-state.json` in Rex's config folder, so reloading the config
  keeps broadcasting on and never loses the labels to put back.
- **Fan-out.** While broadcasting, the function reads the session view and
  writes the key's bytes (for example `\27[A` for up) to every terminal block
  in the tab with the terminal's `write` method.
- **Header icon.** Rex has no way for a config to add an icon next to the pane
  header buttons, so the icon goes in each pane's label. Starting sets the
  label to the name Rex normally shows (program and folder), then the SF
  Symbol `dot.radiowaves.left.and.right` and "Broadcasting · Esc to stop".
  The symbol is the private-use character U+100319, which macOS draws as an
  icon in the system font. Labels are plain text, so there is no color or
  background. A long name is shortened with "…" to fit Rex's 128-character
  label limit.
  Stopping puts the original label back. A pane opened while broadcasting
  gets the mark on the next key you type.

## Limits

- Paste, input methods (such as emoji or CJK input), and the mouse are not
  mirrored.
- Punctuation assumes a US keyboard layout.
- `Escape` stops broadcasting, so it can't be sent to the panes.
- Every bound key passes through a Lua function, even while broadcasting is
  off, which adds a round trip to the Rex server for each key. It was not
  noticeable in testing. If typing ever feels slow, remove
  `require("broadcast")` from `init.lua`.
- Very fast input (dozens of keys within a few milliseconds, as from a script)
  can drop or reorder keys. Normal typing is fine.
- While broadcasting, a pane's header doesn't follow `cd` or a new program;
  it shows the name from when broadcasting started.
- In a narrow pane, Rex cuts the end of the header off, so the note (or the
  icon) may be hidden.
- The icon is an Apple SF Symbol character. It only draws on Apple platforms,
  and Apple could move it to another code point in a later macOS. If it shows
  as a box, change `MARK` in `broadcast.lua`.
