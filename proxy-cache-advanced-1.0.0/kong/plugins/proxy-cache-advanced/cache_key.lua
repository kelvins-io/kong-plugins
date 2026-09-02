---
--- Created by kelvins-io.
--- DateTime: 2026/1/10 16:03
---
local fmt = string.format
local ipairs = ipairs
local type = type
local pairs = pairs
local sort = table.sort
local insert = table.insert
local concat = table.concat
local tostring = tostring

--local sha256_hex = require "kong.tools.utils".sha256_hex
local sha256_hex
do
  local ok, sha256 = pcall(require, "kong.tools.sha256")
  if ok and sha256 and sha256.sha256_hex then
    sha256_hex = sha256.sha256_hex
  else
    sha256_hex = require("kong.tools.utils").sha256_hex
  end
end
local cjson = require "cjson.safe"
local json_null = cjson.null

local _M = {}


local EMPTY = {}


local function keys(t)
  local res = {}
  for k, _ in pairs(t) do
    res[#res+1] = k
  end

  return res
end


-- Return a string with the format "key=value(:key=value)*" of the
-- actual keys and values in args that are in vary_fields.
--
-- The elements are sorted so we get consistent cache actual_keys no matter
-- the order in which params came in the request
local function generate_key_from(args, vary_fields)
  local cache_key = {}

  for _, field in ipairs(vary_fields or {}) do
    local arg = args[field]
    if arg then
      if type(arg) == "table" then
        sort(arg)
        insert(cache_key, field .. "=" .. concat(arg, ","))

      elseif arg == true then
        insert(cache_key, field)

      else
        insert(cache_key, field .. "=" .. tostring(arg))
      end
    end
  end

  return concat(cache_key, ":")
end


-- Return the component of cache_key for vary_query_params in params
--
-- If no vary_query_params are configured in the plugin, return
-- all of them.
local function params_key(params, plugin_config)
  if not (plugin_config.vary_query_params or EMPTY)[1] then
    local actual_keys = keys(params)
    sort(actual_keys)
    return generate_key_from(params, actual_keys)
  end

  return generate_key_from(params, plugin_config.vary_query_params)
end
_M.params_key = params_key


-- Return the component of cache_key for vary_headers in params
--
-- If no vary_query_params are configured in the plugin, return
-- the empty string.
local function headers_key(headers, plugin_config)
  if not (plugin_config.vary_headers or EMPTY)[1] then
    return ""
  end

  return generate_key_from(headers, plugin_config.vary_headers)
end
_M.headers_key = headers_key


local function prefix_uuid(consumer_id, route_id)

  -- authenticated route
  if consumer_id and route_id then
    return fmt("%s:%s", consumer_id, route_id)
  end

  -- unauthenticated route
  if route_id then
    return route_id
  end

  -- global default
  return "default"
end
_M.prefix_uuid = prefix_uuid


local function json_get(body, path)
  if type(body) ~= "table" or not path or path == "" then
    return nil
  end

  local cur = body
  for segment in path:gmatch("[^.]+") do
    if type(cur) ~= "table" then
      return nil
    end
    local v = cur[segment]
    if v == nil or v == json_null then
      return nil
    end
    cur = v
  end

  return cur
end


local function is_array(t)
  local n = #t
  if n == 0 then
    for _ in pairs(t) do
      return false
    end
    return true
  end

  local count = 0
  for k, _ in pairs(t) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
      return false
    end
    count = count + 1
  end

  return count == n
end


local function canonical_encode(val)
  if val == nil or val == json_null then
    return "null"
  end

  local t = type(val)
  if t == "string" then
    return cjson.encode(val) or ""
  end

  if t == "number" then
    return tostring(val)
  end

  if t == "boolean" then
    return val and "true" or "false"
  end

  if t ~= "table" then
    return ""
  end

  if is_array(val) then
    local parts = {}
    for i = 1, #val do
      parts[i] = canonical_encode(val[i])
    end
    return "[" .. concat(parts, ",") .. "]"
  end

  local ks = {}
  for k, _ in pairs(val) do
    if type(k) == "string" then
      ks[#ks + 1] = k
    end
  end
  sort(ks)

  local parts = {}
  for i = 1, #ks do
    local k = ks[i]
    parts[i] = cjson.encode(k) .. ":" .. canonical_encode(val[k])
  end

  return "{" .. concat(parts, ",") .. "}"
end


local function scalar_str(val)
  if val == nil or val == json_null then
    return ""
  end

  local t = type(val)
  if t == "string" or t == "number" or t == "boolean" then
    return tostring(val)
  end

  return canonical_encode(val)
end


local function first_json_field(body, primary, fallbacks)
  local v = json_get(body, primary)
  if v ~= nil then
    return v
  end

  for i = 1, #fallbacks do
    v = json_get(body, fallbacks[i])
    if v ~= nil then
      return v
    end
  end

  return nil
end


-- model_id + prompt hash + temperature (+ stream, to avoid SSE/JSON collisions)
function _M.llm_digest(raw_body, llm_conf)
  if type(raw_body) ~= "string" or raw_body == "" then
    return nil
  end

  local body = cjson.decode(raw_body)
  if type(body) ~= "table" then
    return nil
  end

  llm_conf = llm_conf or EMPTY

  local model = first_json_field(body, llm_conf.model_field or "model", {
    "model_id", "model",
  })
  local prompt = first_json_field(body, llm_conf.prompt_field or "messages", {
    "prompt", "messages", "input",
  })
  local temperature = first_json_field(body, llm_conf.temperature_field or "temperature", {
    "temperature",
  })

  local prompt_hash = ""
  if prompt ~= nil then
    local encoded
    if type(prompt) == "string" then
      encoded = prompt
    else
      encoded = canonical_encode(prompt)
    end
    prompt_hash = sha256_hex(encoded)
  end

  local stream = body.stream
  local stream_str = (stream == true or stream == "true") and "1" or "0"

  return fmt("mid=%s:ph=%s:temp=%s:stream=%s",
             scalar_str(model), prompt_hash, scalar_str(temperature), stream_str)
end


function _M.build_cache_key(consumer_id, route_id, method, uri,
                            params_table, headers_table, conf, llm_digest)

  -- obtain cache key components
  local prefix_digest  = prefix_uuid(consumer_id, route_id)
  local params_digest  = params_key(params_table, conf)
  local headers_digest = headers_key(headers_table, conf)

  if llm_digest and llm_digest ~= "" then
    return sha256_hex(fmt("%s|%s|%s|%s|%s|%s", prefix_digest, method, uri,
                                            params_digest, headers_digest, llm_digest))
  end

  return sha256_hex(fmt("%s|%s|%s|%s|%s", prefix_digest, method, uri,
                                          params_digest, headers_digest))
end


return _M
