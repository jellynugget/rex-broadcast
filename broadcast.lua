-- broadcast.lua: send input to every terminal pane in the current tab.
--
-- Press cmd+shift+i to start broadcasting in the current tab: each typing key
-- is then sent to every terminal pane in that tab, and each of those panes
-- shows a broadcast icon and "Broadcasting · ⇧⌘I to stop" after the name in
-- its header. Press cmd+shift+i again to stop. Escape is broadcast like any
-- other key, since fzf, vim and many prompts need it.
--
-- This does not use a Rex key mode, because Rex shows a pop-up listing every
-- key of an active mode, and that cannot be turned off. Instead each typing
-- key is bound to a small Lua function. While broadcasting is off, the
-- function returns false at once and the key goes to the focused pane as
-- usual.
--
-- Install: run ./install.sh from the rex-broadcast repo (see README.md), or
-- put this file in Rex's config folder, add this line to init.lua, then run
-- `rex config reload`:
--
--   require("broadcast").setup()
--
-- Options, all optional:
--
--   require("broadcast").setup{
--     key = "cmd+shift+i",  -- starts and stops broadcasting
--     stop_key = false,     -- another key that also stops it, such as "escape"
--   }

local M = {}

local TERMINAL = "com.superlogical.terminal"
-- Added after the pane name: the SF Symbol "dot.radiowaves.left.and.right"
-- (U+100319, written as UTF-8 bytes because Lua 5.1 has no \u escape), then
-- a short note. macOS draws Apple's private-use SF Symbols characters as icons
-- in Rex's pane headers. Labels are plain text: no color or background.
local ICON = "\244\128\140\153"
local MAX_LABEL = 128  -- Rex's limit, in characters

-- Rex's config folder: $XDG_CONFIG_HOME/rex, or ~/.config/rex.
local function config_dir()
  local xdg = os.getenv("XDG_CONFIG_HOME")
  if xdg and xdg ~= "" then return xdg .. "/rex" end
  return (os.getenv("HOME") or "") .. "/.config/rex"
end

-- Option name -> { the types it accepts, its default }. A default of nil is
-- filled in by setup().
local OPTIONS = {
  key = { types = { string = true }, default = "cmd+shift+i" },
  stop_key = { types = { string = true, boolean = true }, default = false },
  state_file = { types = { string = true } },  -- where state is kept; for tests
}

local opts = nil   -- the checked options, once setup() has run
local mark_text = nil  -- what goes after each pane's name while broadcasting

-- While broadcasting:
--   { session_id = ..., window_id = ..., labels = { [block_id] = old label } }
-- nil when off. Saved to opts.state_file so a config reload neither stops
-- broadcasting nor forgets the labels to put back.
local state = nil

local function warn(message)
  if rex and rex.log then rex.log("warn", "broadcast: " .. message) end
end

-- Split UTF-8 text into characters (Lua 5.1 has no utf8 library).
local function utf8_chars(text)
  local chars = {}
  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
  return chars
end

-- A key in Rex's binding syntax, written the way macOS menus show it, such
-- as "⇧⌘I" for "cmd+shift+i".
local MOD_SYMBOLS = {
  ctrl = "\226\140\131", alt = "\226\140\165", opt = "\226\140\165", option = "\226\140\165",
  shift = "\226\135\167", cmd = "\226\140\152", super = "\226\140\152",
}
local MOD_ORDER = { "ctrl", "alt", "opt", "option", "shift", "cmd", "super" }  -- macOS order: ⌃⌥⇧⌘
local KEY_NAMES = { escape = "Esc", space = "Space", enter = "\226\134\169", tab = "\226\135\165",
  backspace = "\226\140\171", delete = "\226\140\166" }
local function format_key(key)
  local parts = {}
  for part in key:gmatch("[^+]+") do parts[#parts + 1] = part:lower() end
  local base = table.remove(parts) or ""
  local held = {}
  for _, mod in ipairs(parts) do held[mod] = true end
  local out = ""
  for _, mod in ipairs(MOD_ORDER) do
    if held[mod] and not out:find(MOD_SYMBOLS[mod], 1, true) then out = out .. MOD_SYMBOLS[mod] end
  end
  if KEY_NAMES[base] then return out .. KEY_NAMES[base] end
  if #base == 1 then return out .. base:upper() end
  return out .. base:sub(1, 1):upper() .. base:sub(2)
end
M.format_key = format_key

-- The mark shown after each pane's name, such as
-- "  ((•)) Broadcasting · ⇧⌘I to stop". It names stop_key if set, since that
-- is the quicker key, and the toggle key otherwise.
local function make_mark(key, stop_key)
  local how = format_key(stop_key or key)
  return "  " .. ICON .. " Broadcasting \194\183 " .. how .. " to stop"  -- \194\183 is "·"
end

-- name plus mark, shortening the name so the label fits Rex's limit.
local function marked_label(name, mark)
  mark = mark or mark_text or make_mark(OPTIONS.key.default, false)
  local room = MAX_LABEL - #utf8_chars(mark)
  local chars = utf8_chars(name)
  if #chars > room then
    name = table.concat(chars, "", 1, room - 1) .. "\226\128\166"  -- "…"
  end
  return name .. mark
end
M.marked_label = marked_label

local function save_state()
  if state then
    local f = io.open(opts.state_file, "w")
    if f then f:write(rex.json.encode(state)); f:close() end
  else
    os.remove(opts.state_file)
  end
end

-- The state saved by an earlier load of this file, or nil if there is none or
-- it can't be read.
local function load_state()
  local f = io.open(opts.state_file, "r")
  if not f then return nil end
  local text = f:read("*a"); f:close()
  local ok, s = pcall(rex.json.decode, text)
  if ok and type(s) == "table" and type(s.session_id) == "string"
      and type(s.window_id) == "string" then
    if type(s.labels) ~= "table" then s.labels = {} end
    return s
  end
  warn("ignoring unreadable state file " .. opts.state_file)
  return nil
end

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

-- Call a block method, returning nil instead of raising if it fails.
local function call(method, args)
  local ok, result, err = pcall(rex.block.call, TERMINAL, method, args)
  if not ok then return nil, result end
  return result, err
end

-- Set a pane's label, returning false instead of raising if it fails, as it
-- does for a pane that was closed or a session from before a server restart.
local function set_label(session_id, block_id, label)
  local ok, result, err = pcall(rex.session.set_block_label, {
    session_id = session_id, block_id = block_id, label = label,
  })
  return ok and result ~= nil, ok and err or result
end

-- The name Rex normally shows in a pane header: the program and its folder,
-- such as "zsh ~/github/project".
local function pane_name(block_id)
  local p = call("process", { block_id = block_id })
  local fg = type(p) == "table" and p.foreground
  if type(fg) == "table" and fg.name then
    local cwd = fg.cwd or ""
    local home = p.home or os.getenv("HOME") or ""
    if home ~= "" and cwd:sub(1, #home) == home then cwd = "~" .. cwd:sub(#home + 1) end
    return (cwd ~= "") and (fg.name .. " " .. cwd) or fg.name
  end
  local t = call("title", { block_id = block_id })
  return (type(t) == "table" and t.title and t.title ~= "") and t.title or "broadcasting"
end

-- Show the pane's name followed by the mark in its header, remembering its
-- old label so stop() can put it back. Rex has no way for a config to add an
-- icon next to the header buttons, so the label carries the mark.
local function mark(block)
  if state.labels[block.block_id] ~= nil then return end
  local old = block.label or ""
  -- A label that already has the mark was left by a broadcast whose state
  -- was lost; putting it back would leave the mark stuck, so use the default.
  if old:find(ICON, 1, true) then old = "" end
  state.labels[block.block_id] = old
  set_label(state.session_id, block.block_id, marked_label(pane_name(block.block_id)))
  save_state()
end

-- Write bytes to every terminal in the active window. Returns how many panes
-- got them.
local function broadcast(data, view)
  local sent = 0
  for _, block in ipairs(window_terminals(view)) do
    mark(block)  -- panes opened while broadcasting get the mark too
    local ok, err = call("write", { block_id = block.block_id, data = data })
    if ok then sent = sent + 1 else warn("write failed: " .. tostring(err)) end
  end
  return sent
end

-- Stop broadcasting and put the panes' labels back.
local function stop()
  if not state then return { stopped = false } end
  for id, label in pairs(state.labels) do
    -- A pane closed meanwhile fails with not_found; that's fine.
    -- An empty label would become "Block xxxx", so fall back to "shell",
    -- the label Rex gives a new shell pane.
    set_label(state.session_id, id, (label ~= "" and label) or "shell")
  end
  state = nil
  save_state()
  return { stopped = true }
end

-- Start broadcasting in the tab the view shows, first stopping any broadcast
-- in another tab. Returns a result table.
local function start(view)
  local err
  if not view then view, err = rex.session.view{} end
  if not view then return { error = err or "no session" } end
  local win = active_window(view)
  if not win then return { error = "no active window" } end
  if state then stop() end
  state = { session_id = view.session_id, window_id = win.window_id, labels = {} }
  for _, block in ipairs(window_terminals(view)) do mark(block) end
  save_state()
  return { started = true }
end

-- True if the view shows the tab being broadcast to.
local function is_broadcast_tab(view)
  return state ~= nil and type(view) == "table"
    and view.session_id == state.session_id
    and view.active_window_id == state.window_id
end

-- If this key press should be broadcast, return the session view to use.
-- Otherwise return nil, and the key goes to the focused pane as usual.
local function broadcast_view(ctx)
  if not state then return nil end
  if ctx and ctx.session_id and ctx.session_id ~= state.session_id then return nil end
  local view = rex.session.view{}
  if not is_broadcast_tab(view) then return nil end
  return view
end

-- Stop if this tab is broadcasting; otherwise start here. Starting in another
-- tab, or after a server restart left old state behind, moves broadcasting
-- to this tab.
local function toggle()
  local view, err = rex.session.view{}
  if is_broadcast_tab(view) then return stop() end
  return start(view)
end

-- Check the options given to setup(). A wrong type or unknown name is logged
-- and ignored.
local function check_options(given)
  local checked = {}
  if type(given) ~= "table" then
    if given ~= nil then warn("setup() takes a table of options; ignoring " .. type(given)) end
    given = {}
  end
  for name, value in pairs(given) do
    local spec = OPTIONS[name]
    if not spec then
      warn("unknown option " .. tostring(name))
    elseif not spec.types[type(value)] or value == true then
      warn("option " .. name .. " can't be " .. tostring(value) .. "; using the default")
    else
      checked[name] = value
    end
  end
  for name, spec in pairs(OPTIONS) do
    if checked[name] == nil then checked[name] = spec.default end
  end
  checked.state_file = checked.state_file or (config_dir() .. "/.broadcast-state.json")
  return checked
end

-- Bind one typing key. `data` is the bytes the key types in a terminal.
local function bcast(key, data)
  rex.bind(key, function(ctx, ev)
    local view = broadcast_view(ctx)
    if not view then return false end
    broadcast(data, view)
    return true
  end)
end

-- Every typing key and the bytes it sends.
local function typing_keys()
  local keys = {}
  local function add(key, data) keys[#keys + 1] = { key, data } end
  -- Letters, with shift and ctrl.
  for c = string.byte("a"), string.byte("z") do
    local ch = string.char(c)
    add(ch, ch)
    add("shift+" .. ch, ch:upper())
    add("ctrl+" .. ch, string.char(c - 96))
  end
  -- Digits and punctuation on a US layout: unshifted, then shifted.
  local us = {
    { "1", "!" }, { "2", "@" }, { "3", "#" }, { "4", "$" }, { "5", "%" },
    { "6", "^" }, { "7", "&" }, { "8", "*" }, { "9", "(" }, { "0", ")" },
    { "-", "_" }, { "=", "+" }, { "[", "{" }, { "]", "}" }, { "\\", "|" },
    { ";", ":" }, { "'", "\"" }, { ",", "<" }, { ".", ">" }, { "/", "?" },
    { "`", "~" },
  }
  for _, k in ipairs(us) do
    add(k[1], k[1])
    add("shift+" .. k[1], k[2])
  end
  -- Named keys.
  add("space", " ")
  add("shift+space", " ")
  add("enter", "\r")
  add("shift+enter", "\r")
  add("tab", "\t")
  add("shift+tab", "\27[Z")
  add("backspace", "\127")
  add("alt+backspace", "\27\127")
  add("delete", "\27[3~")
  add("up", "\27[A")
  add("down", "\27[B")
  add("right", "\27[C")
  add("left", "\27[D")
  add("home", "\27[H")
  add("end", "\27[F")
  add("pageup", "\27[5~")
  add("pagedown", "\27[6~")
  return keys
end
M.typing_keys = typing_keys

-- Set up broadcasting: bind the keys and add the actions. Returns the module.
function M.setup(given)
  opts = check_options(given)
  mark_text = make_mark(opts.key, opts.stop_key)
  state = load_state()

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
  rex.action{
    name = "broadcast_toggle",
    title = "Broadcast: Toggle Typing in All Panes",
    category = "Broadcast",
    run = function(ctx, args) return toggle() end,
  }

  for _, k in ipairs(typing_keys()) do
    if k[1] ~= opts.key and k[1] ~= opts.stop_key then bcast(k[1], k[2]) end
  end

  rex.bind(opts.key, function(ctx, ev)
    toggle()
    return true
  end)

  if opts.stop_key then
    rex.bind(opts.stop_key, function(ctx, ev)
      if not broadcast_view(ctx) then return false end
      stop()
      return true
    end)
  end
  if opts.stop_key ~= "escape" and opts.key ~= "escape" then
    bcast("escape", "\27")  -- Escape isn't a stop key, so broadcast it like any key
  end

  return M
end

-- True while broadcasting.
function M.active()
  return state ~= nil
end

return M
