-- A small JSON encoder and decoder standing in for rex.json in the tests.
-- Like rex.json.decode, decode returns nil for text that isn't JSON instead
-- of raising.

local json = {}

local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encode_string(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return escapes[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function is_array(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n > 0 and n == #t
end

function json.encode(value)
  local kind = type(value)
  if value == nil then return "null"
  elseif kind == "boolean" or kind == "number" then return tostring(value)
  elseif kind == "string" then return encode_string(value)
  elseif kind == "table" then
    local parts = {}
    if is_array(value) then
      for _, v in ipairs(value) do parts[#parts + 1] = json.encode(v) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
      parts[#parts + 1] = encode_string(k) .. ":" .. json.encode(value[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  error("can't encode a " .. kind)
end

local function decoder(text)
  local pos = 1

  local function fail(why) error({ json = why .. " at " .. pos }) end
  local function skip() pos = text:find("[^ \t\r\n]", pos) or #text + 1 end
  local function peek() skip(); return text:sub(pos, pos) end
  local function expect(s)
    if text:sub(pos, pos + #s - 1) ~= s then fail("expected " .. s) end
    pos = pos + #s
  end

  local value

  local function string_value()
    expect('"')
    local out = {}
    while true do
      local c = text:sub(pos, pos)
      if c == "" then fail("unfinished string") end
      if c == '"' then pos = pos + 1; break end
      if c == "\\" then
        local e = text:sub(pos + 1, pos + 1)
        local simple = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b",
          f = "\f", n = "\n", r = "\r", t = "\t" }
        if simple[e] then out[#out + 1] = simple[e]; pos = pos + 2
        elseif e == "u" then
          local code = tonumber(text:sub(pos + 2, pos + 5), 16)
          if not code or code > 127 then fail("unsupported escape") end
          out[#out + 1] = string.char(code); pos = pos + 6
        else fail("bad escape") end
      else
        out[#out + 1] = c; pos = pos + 1
      end
    end
    return table.concat(out)
  end

  function value()
    local c = peek()
    if c == "{" then
      pos = pos + 1
      local t = {}
      if peek() == "}" then pos = pos + 1; return t end
      while true do
        skip()
        local k = string_value()
        skip(); expect(":")
        t[k] = value()
        local d = peek()
        pos = pos + 1
        if d == "}" then return t end
        if d ~= "," then fail("expected , or }") end
      end
    elseif c == "[" then
      pos = pos + 1
      local t = {}
      if peek() == "]" then pos = pos + 1; return t end
      while true do
        t[#t + 1] = value()
        local d = peek()
        pos = pos + 1
        if d == "]" then return t end
        if d ~= "," then fail("expected , or ]") end
      end
    elseif c == '"' then return string_value()
    elseif text:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif text:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif text:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
    end
    local num = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if not num or num == "" then fail("unexpected " .. (c == "" and "end" or c)) end
    pos = pos + #num
    return tonumber(num)
  end

  local result = value()
  if peek() ~= "" then fail("trailing text") end
  return result
end

function json.decode(text)
  if type(text) ~= "string" then return nil end
  local ok, result = pcall(decoder, text)
  if ok then return result end
  if type(result) == "table" and result.json then return nil end
  error(result, 0)
end

return json
