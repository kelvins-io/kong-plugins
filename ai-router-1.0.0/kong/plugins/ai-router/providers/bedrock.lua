-- Amazon Bedrock Converse API（Bearer API Key 鉴权）。
local cjson = require "cjson.safe"
local tools = require "kong.plugins.ai-router.tools"

local ngx = ngx
local type = type
local pairs = pairs
local next = next
local tostring = tostring


local _M = {}


local function region_of(resolved)
  return resolved.aws_region_name or resolved.aws_region or "us-east-1"
end


local function model_id(resolved)
  -- litellm style: bedrock/us.anthropic.claude-... or bedrock/anthropic.claude-...
  return resolved.upstream_model
end


local function base_url(resolved)
  if resolved.api_base and resolved.api_base ~= "" then
    return (resolved.api_base):gsub("/+$", "")
  end
  return "https://bedrock-runtime." .. region_of(resolved) .. ".amazonaws.com"
end


function _M.build(conf, resolved, endpoint, client_body, client_model)
  if endpoint ~= "chat" then
    return nil, "bedrock provider only supports chat/completions"
  end

  local messages, system = tools.openai_messages_to_bedrock(client_body.messages)
  local body = {
    messages = messages,
  }
  if system then
    body.system = system
  end

  local inference = {}
  local max_tokens = client_body.max_tokens or client_body.max_completion_tokens or resolved.max_tokens
  if max_tokens then
    inference.maxTokens = max_tokens
  end
  local temperature = client_body.temperature
  if temperature == nil then
    temperature = resolved.temperature
  end
  if temperature ~= nil then
    inference.temperature = temperature
  end
  if client_body.top_p ~= nil then
    inference.topP = client_body.top_p
  end
  if client_body.stop ~= nil then
    inference.stopSequences = type(client_body.stop) == "table" and client_body.stop or { client_body.stop }
  end
  if next(inference) then
    body.inferenceConfig = inference
  end

  local bedrock_tools = tools.openai_tools_to_bedrock(client_body.tools)
  if bedrock_tools and client_body.tool_choice ~= "none" then
    body.toolConfig = {
      tools = bedrock_tools,
      toolChoice = tools.openai_tool_choice_to_bedrock(client_body.tool_choice),
    }
  end

  local mid = model_id(resolved)
  local stream = client_body.stream == true
  local path = "/model/" .. ngx.escape_uri(mid) .. (stream and "/converse-stream" or "/converse")
  local url = base_url(resolved) .. path

  local headers = {
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/json",
  }
  if resolved.api_key and resolved.api_key ~= "" then
    headers["Authorization"] = "Bearer " .. resolved.api_key
  end
  if type(resolved.extra_headers) == "table" then
    for k, v in pairs(resolved.extra_headers) do
      headers[k] = tostring(v)
    end
  end

  local payload, err = cjson.encode(body)
  if not payload then
    return nil, "failed to encode bedrock request: " .. tostring(err)
  end

  return {
    url = url,
    method = "POST",
    headers = headers,
    body = payload,
    provider = "bedrock",
    upstream_model = mid,
    client_model = client_model,
    stream = stream,
  }
end


local function stop_reason_to_openai(reason, has_tools)
  if has_tools then
    return "tool_calls"
  end
  if reason == "max_tokens" then
    return "length"
  end
  if reason == "content_filtered" then
    return "content_filter"
  end
  return "stop"
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

  local output = obj.output or {}
  local message = output.message or {}
  local text, tool_calls = tools.bedrock_tool_uses_to_openai(message.content)
  local usage = obj.usage or {}
  local openai_obj = {
    id = "chatcmpl-bedrock",
    object = "chat.completion",
    created = ngx.time(),
    model = client_model or message.model,
    choices = {
      {
        index = 0,
        message = {
          role = "assistant",
          content = (text ~= "" and text) or ( #tool_calls > 0 and nil or ""),
          tool_calls = #tool_calls > 0 and tool_calls or nil,
        },
        finish_reason = stop_reason_to_openai(obj.stopReason, #tool_calls > 0),
      },
    },
    usage = {
      prompt_tokens = usage.inputTokens or 0,
      completion_tokens = usage.outputTokens or 0,
      total_tokens = (usage.inputTokens or 0) + (usage.outputTokens or 0) + (usage.totalTokens and 0 or 0),
    },
  }
  if usage.totalTokens then
    openai_obj.usage.total_tokens = usage.totalTokens
  end

  return status, headers, cjson.encode(openai_obj) or body
end


return _M
