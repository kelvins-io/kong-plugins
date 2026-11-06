local cjson = require "cjson.safe"

local type = type
local tostring = tostring


local _M = {}


local function trim_slash(s)
  return (s or ""):gsub("/+$", "")
end


local function endpoint_segment(endpoint)
  if endpoint == "chat" then
    return "chat/completions"
  end
  if endpoint == "completions" then
    return "completions"
  end
  if endpoint == "embeddings" then
    return "embeddings"
  end
  return "chat/completions"
end


local function copy_body(src)
  local dst = {}
  if type(src) ~= "table" then
    return dst
  end
  for k, v in pairs(src) do
    dst[k] = v
  end
  return dst
end


local function ensure_stream_usage(body)
  if body.stream ~= true then
    return
  end
  if type(body.stream_options) ~= "table" then
    body.stream_options = {}
  end
  if body.stream_options.include_usage == nil then
    body.stream_options.include_usage = true
  end
end


function _M.build(conf, resolved, endpoint, client_body, client_model)
  local body = copy_body(client_body)
  -- Azure uses deployment name in URL; body.model is optional / ignored
  body.model = nil

  if resolved.max_tokens and body.max_tokens == nil then
    body.max_tokens = resolved.max_tokens
  end
  if resolved.temperature ~= nil and body.temperature == nil then
    body.temperature = resolved.temperature
  end
  ensure_stream_usage(body)

  local base = trim_slash(resolved.api_base)
  local deployment = resolved.upstream_model
  local version = resolved.api_version or "2024-02-15-preview"
  local url = base .. "/openai/deployments/" .. deployment .. "/" ..
    endpoint_segment(endpoint) .. "?api-version=" .. version

  local headers = {
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/json",
  }
  if resolved.api_key and resolved.api_key ~= "" then
    headers["api-key"] = resolved.api_key
  end
  if type(resolved.extra_headers) == "table" then
    for k, v in pairs(resolved.extra_headers) do
      headers[k] = tostring(v)
    end
  end

  local payload, err = cjson.encode(body)
  if not payload then
    return nil, "failed to encode azure request: " .. tostring(err)
  end

  return {
    url = url,
    method = "POST",
    headers = headers,
    body = payload,
    provider = "azure",
    upstream_model = deployment,
    client_model = client_model,
    stream = body.stream == true,
  }
end


function _M.normalize_response(endpoint, status, headers, body, client_model, conf)
  if conf.return_model_in_response and type(body) == "string" and status >= 200 and status < 300 then
    local obj = cjson.decode(body)
    if type(obj) == "table" and client_model then
      obj.model = client_model
      local encoded = cjson.encode(obj)
      if encoded then
        body = encoded
      end
    end
  end
  return status, headers, body
end


return _M
