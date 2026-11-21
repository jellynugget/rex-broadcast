-- broadcast.lua: send input to every terminal pane in the current tab.
--
-- Press cmd+shift+i to start broadcasting in the current tab: each typing key
-- is then sent to every terminal pane in that tab, and each of those panes
-- shows a broadcast icon ((•)) after the title in its header. Press cmd+shift+i again, or Escape, to stop.
--
-- This does not use a Rex key mode, because Rex shows a pop-up listing every
-- key of an active mode, and that cannot be turned off. Instead each typing
-- key is bound to a small Lua function. While broadcasting is off, the
-- function returns false at once and the key goes to the focused pane as
-- usual.
--
-- Install: run ./install.sh from the rex-broadcast repo (see README.md), or
-- put this file in Rex's config folder, add `require("broadcast")` to
-- init.lua, then run `rex config reload`.

local M = {}

-- Rex's config folder: $XDG_CONFIG_HOME/rex, or ~/.config/rex.
local function config_dir()
  local xdg = os.getenv("XDG_CONFIG_HOME")
  if xdg and xdg ~= "" then return xdg .. "/rex" end
  return (os.getenv("HOME") or "") .. "/.config/rex"
end

local TERMINAL = "com.superlogical.terminal"
-- Added after the pane name: the SF Symbol "dot.radiowaves.left.and.right"
-- (U+100319, written as UTF-8 bytes because Lua 5.1 has no \u escape), then
-- a short note. macOS draws Apple's private-use SF Symbols characters as icons
-- in Rex's pane headers. Labels are plain text: no color or background.
local ICON = "\244\128\140\153"
local MARK = "  " .. ICON .. " Broadcasting \194\183 Esc to stop"  -- \194\183 is "·"
local MAX_LABEL = 128  -- Rex's limit, in characters

-- Split UTF-8 text into characters (Lua 5.1 has no utf8 library).
local function utf8_chars(text)
  local chars = {}
  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
  return chars
end

-- Pane name plus MARK, shortening the name so the label fits Rex's limit.
local function marked_label(name)
  local room = MAX_LABEL - #utf8_chars(MARK)
  local chars = utf8_chars(name)
  if #chars > room then
    name = table.concat(chars, "", 1, room - 1) .. "\226\128\166"  -- "…"
  end
  return name .. MARK
end
M.marked_label = marked_label
local STATE_FILE = config_dir() .. "/.broadcast-state.json"

-- While broadcasting:
--   { session_id = ..., window_id = ..., labels = { [block_id] = old label } }
-- nil when off. Saved to STATE_FILE so a config reload neither stops
-- broadcasting nor forgets the labels to put back.
local state = nil

local function save_state()
  if state then
    local f = io.open(STATE_FILE, "w")
    if f then f:write(rex.json.encode(state)); f:close() end
  else
    os.remove(STATE_FILE)
  end
end

local function load_state()
  local f = io.open(STATE_FILE, "r")
  if not f then return nil end
  local text = f:read("*a"); f:close()
  local s = rex.json.decode(text)
  if type(s) == "table" and s.session_id and s.window_id then
    s.labels = s.labels or {}
    return s
  end
end

state = load_state()

local function active_window(view)
  for _, win in ipairs(view.windows or {}) do
    if win.window_id == view.active_window_id then return win end
  end
end

-- Every terminal block in the active window, as { block_id, label } tables.
local function window_terminals(view)
  local blocks = {}
  local win = active_window(view)
  if win then
    for _, layer in ipairs(win.layers or {}) do
      for _, block in ipairs(layer.blocks or {}) do
        if block.creator_name == TERMINAL then blocks[#blocks + 1] = block end
      end
    end
  end
  return blocks
end

-- The name Rex normally shows in a pane header: the program and its folder,
-- such as "zsh ~/github/project".
local function pane_name(block_id)
  local p = rex.block.call(TERMINAL, "process", { block_id = block_id })
  local fg = p and p.foreground
  if fg and fg.name then
    local cwd = fg.cwd or ""
    local home = p.home or os.getenv("HOME") or ""
    if home ~= "" and cwd:sub(1, #home) == home then cwd = "~" .. cwd:sub(#home + 1) end
    return (cwd ~= "") and (fg.name .. " " .. cwd) or fg.name
  end
  local t = rex.block.call(TERMINAL, "title", { block_id = block_id })
  return (t and t.title and t.title ~= "") and t.title or "broadcasting"
end

-- Show the pane's name followed by the broadcast icon in a pane's header, remembering
-- its old label so stop() can put it back. Rex has no way for a config to add
-- an icon next to the header buttons, so the label carries the mark.
local function mark(block)
  if state.labels[block.block_id] ~= nil then return end
  state.labels[block.block_id] = block.label or ""
  local title = pane_name(block.block_id)
  rex.session.set_block_label{
    session_id = state.session_id,
    block_id = block.block_id,
    label = marked_label(title),
  }
  save_state()
end

-- Write bytes to every terminal in the active window.
local function broadcast(data, view)
  local sent = 0
  for _, block in ipairs(window_terminals(view)) do
    mark(block)  -- panes opened while broadcasting get the icon too
    local ok, werr = rex.block.call(TERMINAL, "write", { block_id = block.block_id, data = data })
    if ok then sent = sent + 1 else rex.log("warn", "broadcast write failed: " .. tostring(werr)) end
  end
  return { panes = sent }
end

-- Start broadcasting in the active tab. Returns a result table.
local function start()
  local view, err = rex.session.view{}
  if not view then return { error = err } end
  local win = active_window(view)
  if not win then return { error = "no active window" } end
  state = { session_id = view.session_id, window_id = win.window_id, labels = {} }
  for _, block in ipairs(window_terminals(view)) do mark(block) end
  save_state()
  return { started = true }
end

-- Stop broadcasting and put the panes' labels back.
local function stop()
  if not state then return { stopped = false } end
  for id, label in pairs(state.labels) do
    -- A pane closed meanwhile fails with not_found; that's fine.
    -- An empty label would become "Block xxxx", so fall back to "shell".
    rex.session.set_block_label{
      session_id = state.session_id,
      block_id = id,
      label = (label ~= "" and label) or "shell",
    }
  end
  state = nil
  save_state()
  return { stopped = true }
end

-- If this key press should be broadcast, return the session view to use.
-- Otherwise return nil, and the key goes to the focused pane as usual.
local function broadcast_view(ctx)
  if not state then return nil end
  if ctx.session_id and ctx.session_id ~= state.session_id then return nil end
  local view = rex.session.view{}
  if not view or view.active_window_id ~= state.window_id then return nil end
  return view
end

rex.action{
  name = "broadcast_on",
  title = "Broadcast: Start Typing in All Panes",
  category = "Broadcast",
  keywords = "sync synchronize panes multiple all",
  run = function(ctx, args) return start() end,
}

rex.action{
  name = "broadcast_off",
  title = "Broadcast: Stop Typing in All Panes",
  category = "Broadcast",
  run = function(ctx, args) return stop() end,
}

-- Bind one typing key. `data` is the bytes the key types in a terminal.
local function bcast(key, data)
  rex.bind(key, function(ctx, ev)
    local view = broadcast_view(ctx)
    if not view then return false end
    broadcast(data, view)
    return true
  end)
end

-- Letters, with shift and ctrl.
for c = string.byte("a"), string.byte("z") do
  local ch = string.char(c)
  bcast(ch, ch)
  bcast("shift+" .. ch, ch:upper())
  bcast("ctrl+" .. ch, string.char(c - 96))
end

-- Digits and punctuation on a US layout: unshifted, then shifted.
local us = {
  { "1", "1", "!" }, { "2", "2", "@" }, { "3", "3", "#" }, { "4", "4", "$" },
  { "5", "5", "%" }, { "6", "6", "^" }, { "7", "7", "&" }, { "8", "8", "*" },
  { "9", "9", "(" }, { "0", "0", ")" }, { "-", "-", "_" }, { "=", "=", "+" },
  { "[", "[", "{" }, { "]", "]", "}" }, { "\\", "\\", "|" }, { ";", ";", ":" },
  { "'", "'", "\"" }, { ",", ",", "<" }, { ".", ".", ">" }, { "/", "/", "?" },
  { "`", "`", "~" },
}
for _, k in ipairs(us) do
  bcast(k[1], k[2])
  bcast("shift+" .. k[1], k[3])
end

-- Named keys.
bcast("space", " ")
bcast("shift+space", " ")
bcast("enter", "\r")
bcast("shift+enter", "\r")
bcast("tab", "\t")
bcast("shift+tab", "\27[Z")
bcast("backspace", "\127")
bcast("alt+backspace", "\27\127")
bcast("delete", "\27[3~")
bcast("up", "\27[A")
bcast("down", "\27[B")
bcast("right", "\27[C")
bcast("left", "\27[D")
bcast("home", "\27[H")
bcast("end", "\27[F")
bcast("pageup", "\27[5~")
bcast("pagedown", "\27[6~")

-- cmd+shift+i toggles broadcasting.
rex.bind("cmd+shift+i", function(ctx, ev)
  if state then stop() else start() end
  return true
end)

-- Escape stops broadcasting; otherwise it goes to the pane as usual.
rex.bind("escape", function(ctx, ev)
  if not broadcast_view(ctx) then return false end
  stop()
  return true
end)

return M
