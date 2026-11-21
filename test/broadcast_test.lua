-- Tests for broadcast.lua against the fake rex in fake_rex.lua.
--
--   luajit test/broadcast_test.lua
--
-- Exits 1 if any check fails.

local dir = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):match("^(.*)/[^/]*$") or "."
local root = dir:match("^(.*)/test$") or (dir .. "/..")
local Fake = dofile(dir .. "/fake_rex.lua")

local failed, passed = 0, 0

local function section(name) print("\n" .. name) end

local function check(name, condition, detail)
  if condition then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failed = failed + 1
    print("  FAIL " .. name .. (detail ~= nil and ("\n       " .. tostring(detail)) or ""))
  end
end

local tmp = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
local state_file = tmp .. "/rex-broadcast-test-" .. os.time() .. "-" .. math.random(1, 1e9) .. ".json"

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("*a"); f:close()
  return text
end

local function write_file(path, text)
  local f = assert(io.open(path, "w")); f:write(text); f:close()
end

-- A fresh fake rex and a fresh copy of the module, set up with opts.
-- Leaves the state file alone unless keep_state is false.
local function load(opts, keep_state)
  if not keep_state then os.remove(state_file) end
  local fake = Fake.install()
  local M = dofile(root .. "/broadcast.lua")
  opts = opts or {}
  if opts.state_file == nil then opts.state_file = state_file end
  M.setup(opts)
  return fake, M
end

-- Load again over the same fake, as `rex config reload` does: the module's
-- Lua state starts over and only the state file remains.
local function reload(fake, opts)
  fake.bindings, fake.actions = {}, {}
  local M = dofile(root .. "/broadcast.lua")
  opts = opts or {}
  if opts.state_file == nil then opts.state_file = state_file end
  M.setup(opts)
  return M
end

-- One session with one tab of n panes. Returns the fake, module, session,
-- window and panes.
local function tab(n, opts)
  local fake, M = load(opts)
  local sid = fake:add_session()
  local wid, panes = fake:add_window(sid, n or 3)
  return fake, M, sid, wid, panes
end

local function outputs(fake, panes)
  local out = {}
  for i, id in ipairs(panes) do
    local p = fake:pane(id)
    out[i] = p and p.output or "<closed>"
  end
  return out
end

local function all_equal(list, value)
  for _, v in ipairs(list) do if v ~= value then return false end end
  return true
end

local function show(list)
  local parts = {}
  for i, v in ipairs(list) do parts[i] = string.format("%q", tostring(v)) end
  return "{ " .. table.concat(parts, ", ") .. " }"
end

local function count_chars(s)
  local n = 0
  for _ in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do n = n + 1 end
  return n
end

local function contains(s, part) return s:find(part, 1, true) ~= nil end

local ICON = "\244\128\140\153"

------------------------------------------------------------------------------
section("setup and options")
do
  local fake, M = load()
  check("binds cmd+shift+i", fake.bindings["cmd+shift+i"] ~= nil)
  check("binds escape", fake.bindings["escape"] ~= nil)
  check("binds every typing key", fake.bindings["a"] and fake.bindings["shift+/"] and fake.bindings["pagedown"])
  check("adds the three actions", fake.actions.broadcast_on and fake.actions.broadcast_off and fake.actions.broadcast_toggle)
  check("setup returns the module", M.setup({ state_file = state_file }) == M)
  check("no warnings with no options", #fake:warnings() == 0, show(fake:warnings()))
end
do
  local fake = load({ key = "ctrl+b" })
  local sid = fake:add_session()
  local _, panes = fake:add_window(sid, 2)
  check("a custom key replaces cmd+shift+i", fake.bindings["cmd+shift+i"] == nil)
  fake:press("ctrl+b")
  check("a custom key that is also a typing key toggles instead of typing",
    all_equal(outputs(fake, panes), "") and fake:pane(panes[1]).label:find(ICON, 1, true) ~= nil)
end
do
  local fake = load({ stop_key = false })
  local sid = fake:add_session()
  local _, panes = fake:add_window(sid, 2)
  check("with stop_key = false, Escape goes to the pane while off", fake:press("escape") == false)
  fake:press("cmd+shift+i")
  local label = fake:pane(panes[1]).label
  check("stop_key = false leaves \"Esc to stop\" out of the header",
    contains(label, "Broadcasting") and not contains(label, "Esc"), label)
  check("with stop_key = false, Escape is broadcast", fake:press("escape") == true
    and all_equal(outputs(fake, panes), "\27"), show(outputs(fake, panes)))
  check("and doesn't stop broadcasting", contains(fake:pane(panes[1]).label, ICON))
end
do
  local fake = load({ key = 42, stop_key = true, colour = "red" })
  local w = fake:warnings()
  check("a key of the wrong type is ignored, with a warning",
    fake.bindings["cmd+shift+i"] ~= nil and contains(table.concat(w, "\n"), "option key"), show(w))
  check("stop_key = true is ignored, with a warning",
    fake.bindings["escape"] ~= nil and contains(table.concat(w, "\n"), "option stop_key"), show(w))
  check("an unknown option is ignored, with a warning", contains(table.concat(w, "\n"), "unknown option colour"), show(w))
end
do
  -- Point the default state file at the temp folder, not the real config.
  local getenv = os.getenv
  os.getenv = function(name)
    if name == "XDG_CONFIG_HOME" then return tmp .. "/no-config-" .. os.time() end
    return getenv(name)
  end
  local fake = Fake.install()
  local M = dofile(root .. "/broadcast.lua")
  M.setup("cmd+b")
  os.getenv = getenv
  check("setup with a non-table warns and uses the defaults",
    fake.bindings["cmd+shift+i"] ~= nil and #fake:warnings() == 1, show(fake:warnings()))
end

------------------------------------------------------------------------------
section("while broadcasting is off")
do
  local fake, M, sid, wid, panes = tab(2)
  local passed_through = true
  for _, k in ipairs(M.typing_keys()) do
    if fake:press(k[1]) ~= false then passed_through = false; print("       " .. k[1]) end
  end
  check("every typing key goes to the focused pane as usual", passed_through)
  check("Escape goes to the focused pane as usual", fake:press("escape") == false)
  check("nothing is written to any pane", all_equal(outputs(fake, panes), ""))
  check("no labels change", fake.label_calls == 0)
  check("M.active() is false", M.active() == false)
end

------------------------------------------------------------------------------
section("starting")
do
  local fake, M, sid, wid, panes = tab(3)
  check("cmd+shift+i is handled", fake:press("cmd+shift+i") == true)
  check("M.active() is true", M.active() == true)
  local label = fake:pane(panes[1]).label
  check("each header shows the pane's name, then the icon and note",
    label == "zsh ~/project  " .. ICON .. " Broadcasting \194\183 Esc to stop", label)
  check("every pane in the tab is marked", fake:pane(panes[3]).label == label)
  check("the state file is written", read_file(state_file) ~= nil)
  check("nothing is typed into the panes", all_equal(outputs(fake, panes), ""))
end
do
  local fake, M = load()
  local sid = fake:add_session()
  local wid = fake:add_window(sid, 0)
  local a = fake:add_pane(sid, wid, { process = { home = "/home/u", foreground = { name = "vim", cwd = "/home/u/x" } } })
  local b = fake:add_pane(sid, wid, { process = {}, title = "my title" })
  local c = fake:add_pane(sid, wid, { process = {}, title = "" })
  local d = fake:add_pane(sid, wid, { process = { foreground = { name = "top", cwd = "" } } })
  fake:press("cmd+shift+i")
  local function name(id) return (fake:pane(id).label:gsub("  " .. ICON .. ".*$", "")) end
  check("the home folder is shown as ~", name(a) == "vim ~/x", name(a))
  check("with no process, the terminal title is used", name(b) == "my title", name(b))
  check("with no process or title, \"broadcasting\" is used", name(c) == "broadcasting", name(c))
  check("with no folder, only the program is shown", name(d) == "top", name(d))
end
do
  local fake, M = load()
  local sid = fake:add_session()
  local wid, panes = fake:add_window(sid, 1)
  local other = fake:add_pane(sid, wid, { creator_name = "com.example.browser", label = "web" })
  fake:press("cmd+shift+i")
  fake:type("x")
  check("a pane that isn't a terminal is left alone",
    fake:pane(other).label == "web" and fake:pane(other).output == "")
  check("the terminal pane still gets the keys", fake:pane(panes[1]).output == "x")
end
do
  local fake = load()
  local r = fake:run_action("broadcast_on")
  check("starting with no session returns an error instead of raising", type(r) == "table" and r.error ~= nil)
  local sid = fake:add_session()
  fake.sessions[sid].active_window_id = nil
  r = fake:run_action("broadcast_on")
  check("starting with no tab returns an error", type(r) == "table" and r.error == "no active window")
end

------------------------------------------------------------------------------
section("typing while broadcasting")
do
  local fake, M, sid, wid, panes = tab(3)
  fake:press("cmd+shift+i")
  local results = fake:type("echo Hi!\r")
  check("each key is handled", all_equal(results, true), show(results))
  check("every pane gets the same bytes", all_equal(outputs(fake, panes), "echo Hi!\r"), show(outputs(fake, panes)))
end
do
  local fake, M, sid, wid, panes = tab(2)
  fake:press("cmd+shift+i")
  local wrong = {}
  for _, k in ipairs(M.typing_keys()) do
    for _, id in ipairs(panes) do fake:pane(id).output = "" end
    fake:press(k[1])
    if fake:pane(panes[1]).output ~= k[2] or fake:pane(panes[2]).output ~= k[2] then wrong[#wrong + 1] = k[1] end
  end
  check("every typing key sends its bytes to every pane", #wrong == 0, show(wrong))
end
do
  local _, M = load()
  local seen, dupes = {}, {}
  for _, k in ipairs(M.typing_keys()) do
    if seen[k[1]] then dupes[#dupes + 1] = k[1] end
    seen[k[1]] = k[2]
  end
  check("no typing key is listed twice", #dupes == 0, show(dupes))
  check("ctrl+c sends ETX (\\3)", seen["ctrl+c"] == "\3")
  check("up sends ESC [ A", seen["up"] == "\27[A")
  check("shift+tab sends ESC [ Z", seen["shift+tab"] == "\27[Z")
  check("shift+' sends a double quote", seen["shift+'"] == '"')
  check("escape is not a typing key (it stops broadcasting)", seen["escape"] == nil)
end

------------------------------------------------------------------------------
section("other tabs and sessions")
do
  local fake, M, sid, wid, panes = tab(2)
  local wid2, panes2 = fake:add_window(sid, 2)
  fake:focus_window(sid, wid)
  fake:press("cmd+shift+i")
  fake:focus_window(sid, wid2)
  check("in another tab, keys go to the focused pane as usual", fake:press("a") == false)
  check("in another tab, Escape goes to the pane as usual", fake:press("escape") == false)
  check("the other tab's panes are not marked", fake:pane(panes2[1]).label == "shell")
  check("broadcasting is still on", M.active())
  fake:focus_window(sid, wid)
  fake:type("b")
  check("back in the first tab, keys are broadcast again", all_equal(outputs(fake, panes), "b"), show(outputs(fake, panes)))
end
do
  local fake, M, sid, wid, panes = tab(2)
  fake:press("cmd+shift+i")
  check("a key from another session goes to its pane as usual",
    fake:press("a", { session_id = "session:other" }) == false)
  check("a key with no session in its context is still broadcast", fake:press("a", {}) == true)
end

------------------------------------------------------------------------------
section("stopping")
do
  local fake, M, sid, wid, panes = tab(2)
  fake:pane(panes[2]).label = "my server"
  fake:press("cmd+shift+i")
  check("Escape is handled", fake:press("escape") == true)
  check("broadcasting is off", not M.active())
  check("the default label comes back", fake:pane(panes[1]).label == "shell", fake:pane(panes[1]).label)
  check("a custom label comes back", fake:pane(panes[2]).label == "my server", fake:pane(panes[2]).label)
  check("the state file is removed", read_file(state_file) == nil)
  check("Escape after stopping goes to the pane", fake:press("escape") == false)
  check("keys after stopping go to the pane", fake:press("a") == false)
  check("Escape is never written to the panes", all_equal(outputs(fake, panes), ""))
end
do
  local fake, M, sid, wid, panes = tab(2)
  fake:press("cmd+shift+i")
  check("cmd+shift+i again stops", fake:press("cmd+shift+i") == true and not M.active())
  check("labels come back", fake:pane(panes[1]).label == "shell")
end
do
  local fake, M, sid, wid, panes = tab(1)
  fake:pane(panes[1]).label = ""
  fake:press("cmd+shift+i")
  fake:press("escape")
  check("an empty label comes back as \"shell\", not \"Block xxxx\"", fake:pane(panes[1]).label == "shell")
end
do
  local fake, M = tab(1)
  local r = fake:run_action("broadcast_off")
  check("broadcast_off while off does nothing", r.stopped == false and fake.label_calls == 0)
end

------------------------------------------------------------------------------
section("panes opened or closed while broadcasting")
do
  local fake, M, sid, wid, panes = tab(2)
  fake:press("cmd+shift+i")
  local new = fake:add_pane(sid, wid)
  fake:type("z")
  check("a new pane gets the key", fake:pane(new).output == "z")
  check("a new pane gets the mark", contains(fake:pane(new).label, ICON))
  fake:press("escape")
  check("a new pane's label comes back on stop", fake:pane(new).label == "shell")
end
do
  local fake, M, sid, wid, panes = tab(3)
  fake:press("cmd+shift+i")
  fake:close_pane(panes[2])
  local ok, err = pcall(fake.type, fake, "q")
  check("typing after a pane closed doesn't raise", ok, err)
  check("the open panes still get keys", fake:pane(panes[1]).output == "q" and fake:pane(panes[3]).output == "q")
  ok, err = pcall(fake.press, fake, "escape")
  check("stopping after a pane closed doesn't raise", ok, err)
  check("the open panes' labels come back", fake:pane(panes[1]).label == "shell" and fake:pane(panes[3]).label == "shell")
end
do
  local fake, M, sid, wid, panes = tab(3)
  fake:press("cmd+shift+i")
  fake:close_pane(panes[2])
  fake.raise_errors = true
  local ok, err = pcall(function() fake:type("q"); fake:press("escape") end)
  check("a rex that raises on a closed pane doesn't break typing or stopping", ok, err)
  check("and the other labels still come back", fake:pane(panes[3]).label == "shell")
end
do
  local fake, M, sid, wid, panes = tab(2)
  fake:press("cmd+shift+i")
  fake.failing_writes[panes[1]] = true
  fake:type("w")
  check("a failed write is logged", contains(table.concat(fake:warnings(), "\n"), "write failed"))
  check("a failed write doesn't stop the other panes", fake:pane(panes[2]).output == "w")
end

------------------------------------------------------------------------------
section("moving broadcasting to another tab")
do
  local fake, M, sid, wid, panes = tab(2)
  local wid2, panes2 = fake:add_window(sid, 2)
  fake:focus_window(sid, wid)
  fake:press("cmd+shift+i")
  fake:focus_window(sid, wid2)
  fake:run_action("broadcast_on")
  check("broadcast_on in another tab gives the first tab its labels back", fake:pane(panes[1]).label == "shell")
  check("and marks the new tab", contains(fake:pane(panes2[1]).label, ICON))
  fake:type("m")
  check("keys go to the new tab only",
    all_equal(outputs(fake, panes2), "m") and all_equal(outputs(fake, panes), ""))
end
do
  local fake, M, sid, wid, panes = tab(2)
  local wid2, panes2 = fake:add_window(sid, 2)
  fake:focus_window(sid, wid)
  fake:press("cmd+shift+i")
  fake:focus_window(sid, wid2)
  fake:press("cmd+shift+i")
  check("cmd+shift+i in another tab moves broadcasting there",
    M.active() and contains(fake:pane(panes2[1]).label, ICON) and fake:pane(panes[1]).label == "shell")
  fake:run_action("broadcast_toggle")
  check("broadcast_toggle in that tab stops", not M.active() and fake:pane(panes2[1]).label == "shell")
end

------------------------------------------------------------------------------
section("config reload")
do
  local fake, M, sid, wid, panes = tab(2)
  fake:pane(panes[2]).label = "api"
  fake:press("cmd+shift+i")
  M = reload(fake)
  check("broadcasting stays on after a reload", M.active())
  fake:type("r")
  check("keys are still broadcast after a reload", all_equal(outputs(fake, panes), "r"))
  fake:press("escape")
  check("labels from before the reload come back",
    fake:pane(panes[1]).label == "shell" and fake:pane(panes[2]).label == "api", fake:pane(panes[2]).label)
  M = reload(fake)
  check("broadcasting stays off after a reload", not M.active())
end

------------------------------------------------------------------------------
section("the state file")
do
  local cases = {
    { "garbage", "not json {" },
    { "an empty file", "" },
    { "a JSON list", "[1,2]" },
    { "a session_id that isn't text", '{"session_id":5,"window_id":"window:1"}' },
    { "no window_id", '{"session_id":"session:1"}' },
  }
  for _, case in ipairs(cases) do
    write_file(state_file, case[2])
    local fake, M = load({}, true)
    local sid = fake:add_session()
    local _, panes = fake:add_window(sid, 1)
    check("with " .. case[1] .. ", broadcasting starts off",
      not M.active() and fake:press("a") == false and fake:pane(panes[1]).output == "")
  end
  write_file(state_file, "not json {")
  local fake = load({}, true)
  check("an unreadable state file is logged", contains(table.concat(fake:warnings(), "\n"), "unreadable state file"))
end
do
  write_file(state_file, '{"session_id":"session:1","window_id":"window:2"}')
  local fake, M = load({}, true)
  local sid = fake:add_session()
  local wid, panes = fake:add_window(sid, 1)
  check("state with no labels loads", M.active())
  local ok, err = pcall(fake.press, fake, "cmd+shift+i")
  check("and can be stopped or moved", ok, err)
end
do
  local fake, M = load({ state_file = tmp .. "/no-such-dir-" .. os.time() .. "/state.json" })
  local sid = fake:add_session()
  local _, panes = fake:add_window(sid, 2)
  local ok, err = pcall(function() fake:press("cmd+shift+i"); fake:type("s"); fake:press("escape") end)
  check("a state file that can't be written doesn't break broadcasting", ok, err)
  check("keys were broadcast", all_equal(outputs(fake, panes), "s"))
end

do
  local fake, M, sid, wid, panes = tab(2)
  fake:pane(panes[2]).label = "api"
  fake:press("cmd+shift+i")
  os.remove(state_file)  -- lost while the panes still show the mark
  M = reload(fake)
  check("with the state file gone, broadcasting is off", not M.active())
  fake:press("cmd+shift+i")
  fake:press("escape")
  check("a label still showing an old mark isn't put back with the mark",
    not contains(fake:pane(panes[1]).label, ICON) and not contains(fake:pane(panes[2]).label, ICON),
    fake:pane(panes[2]).label)
  check("it gets the default label instead", fake:pane(panes[2]).label == "shell")
end

------------------------------------------------------------------------------
section("after a server restart")
do
  local fake, M, sid, wid, panes = tab(2)
  fake:press("cmd+shift+i")
  fake:restart_server()
  M = reload(fake)
  local sid2 = fake:add_session()
  local _, panes2 = fake:add_window(sid2, 2)
  check("old state is still loaded", M.active())
  check("keys in the new session go to the focused pane", fake:press("a") == false)
  check("Escape in the new session goes to the pane", fake:press("escape") == false)
  local ok, err = pcall(fake.press, fake, "cmd+shift+i")
  check("cmd+shift+i doesn't raise on the old state", ok, err)
  check("one cmd+shift+i starts broadcasting here, not just stops the old state",
    M.active() and contains(fake:pane(panes2[1]).label, ICON))
  fake:type("k")
  check("and keys are broadcast", all_equal(outputs(fake, panes2), "k"))
end

------------------------------------------------------------------------------
section("shortening long names")
do
  local _, M = load()
  local mark = "  " .. ICON .. " Broadcasting \194\183 Esc to stop"
  local room = 128 - count_chars(mark)
  check("a short name is kept", M.marked_label("zsh ~") == "zsh ~" .. mark)
  local exact = string.rep("a", room)
  check("a name that just fits is kept", M.marked_label(exact) == exact .. mark)
  local over = M.marked_label(string.rep("a", room + 1))
  check("a name one character over is shortened with …",
    over == string.rep("a", room - 1) .. "\226\128\166" .. mark, over)
  check("the shortened label is exactly 128 characters", count_chars(over) == 128, count_chars(over))
  local cjk = string.rep("\228\184\173", 200)  -- 中
  local label = M.marked_label(cjk)
  check("multibyte names are counted in characters, not bytes", count_chars(label) == 128, count_chars(label))
  local whole = label:gsub("[%z\1-\127\194-\244][\128-\191]*", "")
  check("a multibyte name isn't cut in the middle of a character", whole == "", #whole)
  local emoji = M.marked_label(string.rep("\240\159\154\128", 120))  -- 🚀
  check("4-byte characters are counted right", count_chars(emoji) == 128, count_chars(emoji))
  check("an empty name gets only the mark", M.marked_label("") == mark)
end

os.remove(state_file)
print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
