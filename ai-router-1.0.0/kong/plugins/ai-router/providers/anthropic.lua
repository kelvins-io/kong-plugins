local cjson = require "cjson.safe"
local tools = require "kong.plugins.ai-router.tools"

local ngx = ngx
local type = type
local pairs = pairs
local tostring = tostring


local _M = {}


local function trim_slash(s)
  return (s or ""):gsub("/+$", "")
end


local function openai_to_anthropic(body, upstream_model)
  local messages, system = tools.openai_messages_to_anthropic(body.messages)
  local max_tokens = body.max_tokens or body.max_completion_tokens or 1024
  local req = {
    model = upstream_model,
    messages = messages,
    max_tokens = max_tokens,
    stream = body.stream == true or nil,
  }
  if system then
    req.system = system
  end
  if body.temperature ~= nil then
    req.temperature = body.temperature
  end
  if body.top_p ~= nil then
    req.top_p = body.top_p
  end
  if body.stop ~= nil then
    req.stop_sequences = type(body.stop) == "table" and body.stop or { body.stop }
  end

  local anth_tools = tools.openai_tools_to_anthropic(body.tools)
  if anth_tools and body.tool_choice ~= "none" then
    req.tools = anth_tools
    req.tool_choice = tools.openai_tool_choice_to_anthropic(body.tool_choice)
  end

  return req
end


local function anthropic_to_openai(resp, client_model)
  if type(resp) ~= "table" then
    return resp
  end

  local text, tool_calls = tools.anthropic_tool_uses_to_openai(resp.content)
  local usage = resp.usage or {}
  local message = {
    role = "assistant",
    content = (text ~= "" and text) or (#tool_calls > 0 and nil or ""),
  }
  if #tool_calls > 0 then
    message.tool_calls = tool_calls
  end

  local finish = tools.finish_reason_from_tool_calls(tool_calls,
    (resp.stop_reason == "max_tokens" and "length")
      or (resp.stop_reason == "tool_use" and "tool_calls")
      or (resp.stop_reason == "end_turn" and "stop")
      or resp.stop_reason
      or "stop")

  return {
    id = resp.id or "chatcmpl-anthropic",
    object = "chat.completion",
    created = ngx.time(),
    model = client_model or resp.model,
    choices = {
      {
        index = 0,
        message = message,
        finish_reason = finish,
      },
    },
    usage = {
      prompt_tokens = usage.input_tokens or 0,
      completion_tokens = usage.output_tokens or 0,
      total_tokens = (usage.input_tokens or 0) + (usage.output_tokens or 0),
    },
  }
end


function _M.build(conf, resolved, endpoint, client_body, client_model)
  if endpoint ~= "chat" then
    return nil, "anthropic provider only supports chat/completions"
  end

  local anth_body = openai_to_anthropic(client_body, resolved.upstream_model)
  if resolved.max_tokens and (client_body.max_tokens == nil and client_body.max_completion_tokens == nil) then
    anth_body.max_tokens = resolved.max_tokens
  end
  if resolved.temperature ~= nil and client_body.temperature == nil then
    anth_body.temperature = resolved.temperature
  end

  local headers = {
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/json",
    ["anthropic-version"] = "2023-06-01",
  }
  if resolved.api_key and resolved.api_key ~= "" then
    headers["x-api-key"] = resolved.api_key
  end
  if type(resolved.extra_headers) == "table" then
    for k, v in pairs(resolved.extra_headers) do
      headers[k] = tostring(v)
    end
  end

  local url = trim_slash(resolved.api_base) .. "/v1/messages"
  local payload, err = cjson.encode(anth_body)
  if not payload then
    return nil, "failed to encode anthropic request: " .. tostring(err)
  end

  return {
    url = url,
    method = "POST",
    headers = headers,
    body = payload,
    provider = "anthropic",
    upstream_model = resolved.upstream_model,
    client_model = client_model,
    stream = anth_body.stream == true,
  }
end


function _M.normalize_response(endpoint, status, headers, body, client_model, conf)
  if status < 200 or status >= 300 or type(body) ~= "string" then
    return status, headers, body
  end

  local obj = cjson.decode(body)
  if type(obj) ~= "table" then
    return status, headers, body
  end

  if obj.choices then
    if conf.return_model_in_response and client_model then
      obj.model = client_model
    end
    return status, headers, cjson.encode(obj) or body
  end

  local openai_obj = anthropic_to_openai(obj, client_model)
  return status, headers, cjson.encode(openai_obj) or body
end


return _M
