-- An in-memory stand-in for the `rex` global that broadcast.lua talks to:
-- sessions with windows (tabs) of terminal panes, the key bindings and actions
-- the module registers, and everything written to each pane.
--
--   local fake = dofile("test/fake_rex.lua").install(dir)
--   local sid = fake:add_session()
--   local wid, panes = fake:add_window(sid, 3)
--   fake:press("a")            -- runs the "a" binding, as Rex would
--   fake:type("ls\r")          -- presses the key for each character
--   fake:pane(panes[1]).output -- what was written to that pane
--
-- Like the real rex, a call for a closed pane or a session that is gone
-- returns nil and an error. Set fake.raise_errors to make them raise instead.

local dir = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):match("^(.*)/[^/]*$") or "."
local json = dofile(dir .. "/json.lua")

local TERMINAL = "com.superlogical.terminal"

local Fake = {}
Fake.__index = Fake

-- Replace the rex global with a new fake. Returns the fake.
function Fake.install()
  local fake = setmetatable({}, Fake)
  fake:reset()
  rex = fake:api()
  return fake
end

-- Forget every session, binding, action and log line.
function Fake:reset()
  self.sessions = {}      -- [session_id] = { windows = { window... }, active_window_id }
  self.current = nil      -- the session rex.session.view{} shows
  self.bindings = {}      -- [key] = function
  self.actions = {}       -- [name] = the table given to rex.action
  self.logs = {}          -- { level, message }
  self.label_calls = 0    -- how many times set_block_label was called
  self.raise_errors = false
  self.failing_writes = {} -- [block_id] = true for panes whose write fails
  self.next_id = 0
end

function Fake:new_id(kind)
  self.next_id = self.next_id + 1
  return kind .. ":" .. self.next_id
end

-- Add a session and make it current. Returns its ID.
function Fake:add_session()
  local id = self:new_id("session")
  self.sessions[id] = { windows = {}, active_window_id = nil }
  self.current = id
  return id
end

-- Add a window with n terminal panes and make it active. Returns its ID and a
-- list of the panes' block IDs.
function Fake:add_window(session_id, n)
  local s = self.sessions[session_id]
  local win = { window_id = self:new_id("window"), blocks = {} }
  s.windows[#s.windows + 1] = win
  s.active_window_id = win.window_id
  local ids = {}
  for i = 1, n do ids[i] = self:add_pane(session_id, win.window_id) end
  return win.window_id, ids
end

function Fake:window(session_id, window_id)
  for _, win in ipairs(self.sessions[session_id].windows) do
    if win.window_id == window_id then return win end
  end
end

-- Add a pane to a window. opts may set label, creator_name, process, title.
-- Returns its block ID.
function Fake:add_pane(session_id, window_id, opts)
  opts = opts or {}
  local id = self:new_id("block")
  local win = self:window(session_id, window_id)
  win.blocks[#win.blocks + 1] = {
    block_id = id,
    label = opts.label or "shell",
    creator_name = opts.creator_name or TERMINAL,
    process = opts.process or { home = "/Users/me",
      foreground = { name = "zsh", cwd = "/Users/me/project" } },
    title = opts.title,
    output = "",
  }
  return id
end

-- The pane with this block ID, in any session, or nil.
function Fake:pane(block_id)
  for sid, s in pairs(self.sessions) do
    for _, win in ipairs(s.windows) do
      for _, b in ipairs(win.blocks) do
        if b.block_id == block_id then return b, sid end
      end
    end
  end
end

function Fake:close_pane(block_id)
  for _, s in pairs(self.sessions) do
    for _, win in ipairs(s.windows) do
      for i, b in ipairs(win.blocks) do
        if b.block_id == block_id then table.remove(win.blocks, i); return end
      end
    end
  end
end

function Fake:focus_window(session_id, window_id)
  self.sessions[session_id].active_window_id = window_id
  self.current = session_id
end

-- Forget every session, as a server restart that doesn't restore them would.
function Fake:restart_server()
  self.sessions = {}
  self.current = nil
end

-- Run the binding for key, as Rex does when the key is pressed. Returns what
-- the binding returned, or "unbound".
function Fake:press(key, ctx)
  local fn = self.bindings[key]
  if not fn then return "unbound" end
  return fn(ctx or { session_id = self.current }, { key = key })
end

-- The key Rex reports for a character on a US keyboard.
local shifted = { ["!"] = "1", ["@"] = "2", ["#"] = "3", ["$"] = "4", ["%"] = "5",
  ["^"] = "6", ["&"] = "7", ["*"] = "8", ["("] = "9", [")"] = "0", _ = "-",
  ["+"] = "=", ["{"] = "[", ["}"] = "]", ["|"] = "\\", [":"] = ";", ['"'] = "'",
  ["<"] = ",", [">"] = ".", ["?"] = "/", ["~"] = "`" }
local named = { [" "] = "space", ["\r"] = "enter", ["\t"] = "tab", ["\127"] = "backspace" }

function Fake.key_for(ch)
  if named[ch] then return named[ch] end
  if ch:match("%u") then return "shift+" .. ch:lower() end
  if shifted[ch] then return "shift+" .. shifted[ch] end
  return ch
end

-- Press the key for each character of text. Returns the list of results.
function Fake:type(text, ctx)
  local results = {}
  for ch in text:gmatch(".") do results[#results + 1] = self:press(Fake.key_for(ch), ctx) end
  return results
end

function Fake:run_action(name)
  return self.actions[name].run({ session_id = self.current }, {})
end

function Fake:warnings()
  local found = {}
  for _, l in ipairs(self.logs) do
    if l[1] == "warn" then found[#found + 1] = l[2] end
  end
  return found
end

-- A copy of a session's view, shaped like rex.session.view's result.
function Fake:view(session_id)
  local s = self.sessions[session_id]
  if not s then return nil end
  local view = { session_id = session_id, active_window_id = s.active_window_id, windows = {} }
  for _, win in ipairs(s.windows) do
    local blocks = {}
    for _, b in ipairs(win.blocks) do
      blocks[#blocks + 1] = { block_id = b.block_id, label = b.label, creator_name = b.creator_name }
    end
    view.windows[#view.windows + 1] = { window_id = win.window_id, layers = { { blocks = blocks } } }
  end
  return view
end

function Fake:failure(message)
  if self.raise_errors then error(message, 2) end
  return nil, message
end

-- The rex global.
function Fake:api()
  local fake = self
  return {
    bind = function(key, fn) fake.bindings[key] = fn end,
    action = function(t) fake.actions[t.name] = t end,
    log = function(level, message) fake.logs[#fake.logs + 1] = { level, message } end,
    json = { encode = json.encode, decode = json.decode },
    session = {
      view = function(args)
        if not fake.current then return fake:failure("no session") end
        return fake:view(fake.current)
      end,
      set_block_label = function(args)
        fake.label_calls = fake.label_calls + 1
        local b, sid = fake:pane(args.block_id)
        if not b or sid ~= args.session_id then return fake:failure("not_found") end
        if type(args.label) ~= "string" or #args.label == 0 then return fake:failure("bad_request") end
        b.label = args.label
        return {}
      end,
    },
    block = {
      call = function(creator, method, args)
        local b = fake:pane(args.block_id)
        if not b or b.creator_name ~= creator then return fake:failure("not_found") end
        if method == "write" then
          if fake.failing_writes[b.block_id] then return fake:failure("write failed") end
          b.output = b.output .. args.data
          return {}
        elseif method == "process" then
          return b.process
        elseif method == "title" then
          return { title = b.title }
        end
        return fake:failure("unknown method " .. method)
      end,
    },
  }
end

return Fake
