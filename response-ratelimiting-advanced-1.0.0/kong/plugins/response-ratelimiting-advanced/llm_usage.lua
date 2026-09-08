local cjson = require "cjson.safe"


local type = type
local pairs = pairs
local tonumber = tonumber
local concat = table.concat


local strip
do
  local ok, kong_string = pcall(require, "kong.tools.string")
  if ok and kong_string.strip then
    strip = kong_string.strip
  else
    strip = require("kong.tools.utils").strip
  end
end


local _M = {}


function _M.enabled(conf)
  return conf.llm_usage == true or conf.llm_usage == "true"
end


function _M.is_sse_content_type(ct)
  if type(ct) == "table" then
    ct = ct[1]
  end
  if type(ct) ~= "string" or ct == "" then
    return false
  end

  ct = ct:lower()
  local semi = ct:find(";", 1, true)
  if semi then
    ct = ct:sub(1, semi - 1)
  end
  return strip(ct) == "text/event-stream"
end


function _M.looks_like_sse(chunk)
  if type(chunk) ~= "string" or chunk == "" then
    return false
  end

  local head = strip(chunk:gsub("\r\n", "\n"):gsub("\r", "\n"))
  local nl = head:find("\n", 1, true)
  if nl then
    head = head:sub(1, nl - 1)
  end
  head = strip(head):sub(1, 64)
  return head:find("^data:") ~= nil or head:find("^event:") ~= nil
end


function _M.increments_from_usage(limits, usage)
  local increments = {}
  if type(usage) ~= "table" then
    return increments
  end

  for k, v in pairs(usage) do
    if limits[k] then
      local n = tonumber(v)
      if n then
        increments[k] = n
      end
    end
  end

  return increments
end


function _M.increments_from_json(limits, json_str)
  if type(json_str) ~= "string" or json_str == "" then
    return {}, "empty body"
  end

  local body, err = cjson.decode(json_str)
  if type(body) ~= "table" then
    return {}, err or "upstream body is not a JSON object"
  end

  if type(body.usage) ~= "table" then
    return {}, "missing usage object in upstream JSON body"
  end

  return _M.increments_from_usage(limits, body.usage)
end


local function is_done_payload(payload)
  local t = strip(payload)
  t = t:gsub("^%[%s*", ""):gsub("%s*%]$", "")
  return t:upper() == "DONE"
end


function _M.payload_from_sse_event(event)
  event = event:gsub("\r\n", "\n"):gsub("\r", "\n")

  local data_parts = {}
  local start = 1
  local len = #event
  while start <= len do
    local nl = event:find("\n", start, true)
    local line
    if nl then
      line = event:sub(start, nl - 1)
      start = nl + 1
    else
      line = event:sub(start)
      start = len + 1
    end

    if line ~= "" and line:byte(1) ~= 58 then
      local data = line:match("^data:%s?(.*)$")
      if data then
        data_parts[#data_parts + 1] = data
      end
    end
  end

  if #data_parts == 0 then
    return nil
  end

  local payload = strip(concat(data_parts, "\n"))
  if payload == "" or is_done_payload(payload) then
    return nil
  end

  return payload
end


function _M.consume_sse(ctx, chunk)
  local buf = (ctx.sse_rest or "") .. (chunk or "")
  buf = buf:gsub("\r\n", "\n"):gsub("\r", "\n")

  local pos = 1
  while true do
    local s, e = buf:find("\n\n", pos, true)
    if not s then
      break
    end

    local payload = _M.payload_from_sse_event(buf:sub(pos, s - 1))
    if payload then
      ctx.sse_last_data = payload
    end
    pos = e + 1
  end

  ctx.sse_rest = buf:sub(pos)
end


function _M.flush_sse(ctx)
  if type(ctx.sse_rest) == "string" and ctx.sse_rest ~= "" then
    local payload = _M.payload_from_sse_event(ctx.sse_rest)
    if payload then
      ctx.sse_last_data = payload
    end
  end
  ctx.sse_rest = nil
end


return _M
