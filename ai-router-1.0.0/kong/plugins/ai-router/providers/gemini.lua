-- Google Gemini generateContent / streamGenerateContent。
local cjson = require "cjson.safe"
local tools = require "kong.plugins.ai-router.tools"

local ngx = ngx
local type = type
local pairs = pairs
local next = next
local tostring = tostring


local _M = {}


local DEFAULT_BASE = "https://generativelanguage.googleapis.com/v1beta"


local function trim_slash(s)
  return (s or ""):gsub("/+$", "")
end


function _M.build(conf, resolved, endpoint, client_body, client_model)
  if endpoint ~= "chat" then
    return nil, "gemini provider only supports chat/completions"
  end

  local contents, systemInstruction = tools.openai_messages_to_gemini(client_body.messages)
  local body = {
    contents = contents,
  }
  if systemInstruction then
    body.systemInstruction = systemInstruction
  end

  local gen = {}
  local max_tokens = client_body.max_tokens or client_body.max_completion_tokens or resolved.max_tokens
  if max_tokens then
    gen.maxOutputTokens = max_tokens
  end
  local temperature = client_body.temperature
  if temperature == nil then
    temperature = resolved.temperature
  end
  if temperature ~= nil then
    gen.temperature = temperature
  end
  if client_body.top_p ~= nil then
    gen.topP = client_body.top_p
  end
  if client_body.stop ~= nil then
    gen.stopSequences = type(client_body.stop) == "table" and client_body.stop or { client_body.stop }
  end
  if next(gen) then
    body.generationConfig = gen
  end

  local gemini_tools = tools.openai_tools_to_gemini(client_body.tools)
  if gemini_tools then
    body.tools = gemini_tools
    body.toolConfig = tools.openai_tool_choice_to_gemini(client_body.tool_choice)
  end

  local stream = client_body.stream == true
  local action = stream and ":streamGenerateContent" or ":generateContent"
  local base = trim_slash(resolved.api_base or DEFAULT_BASE)
  local model = resolved.upstream_model
  -- allow models/xxx or bare name
  if not model:find("^models/", 1) then
    model = "models/" .. model
  end

  local url = base .. "/" .. model .. action
  if resolved.api_key and resolved.api_key ~= "" then
    local sep = url:find("?", 1, true) and "&" or "?"
    url = url .. sep .. "key=" .. ngx.escape_uri(resolved.api_key)
  end
  if stream then
    local sep = url:find("?", 1, true) and "&" or "?"
    url = url .. sep .. "alt=sse"
  end

  local headers = {
    ["Content-Type"] = "application/json",
    ["Accept"] = stream and "text/event-stream" or "application/json",
  }
  if type(resolved.extra_headers) == "table" then
    for k, v in pairs(resolved.extra_headers) do
      headers[k] = tostring(v)
    end
  end

  local payload, err = cjson.encode(body)
  if not payload then
    return nil, "failed to encode gemini request: " .. tostring(err)
  end

  return {
    url = url,
    method = "POST",
    headers = headers,
    body = payload,
    provider = "gemini",
    upstream_model = resolved.upstream_model,
    client_model = client_model,
    stream = stream,
  }
end


local function finish_reason(fr, has_tools)
  if has_tools then
    return "tool_calls"
  end
  if fr == "MAX_TOKENS" then
    return "length"
  end
  if fr == "SAFETY" or fr == "RECITATION" or fr == "BLOCKLIST" then
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

  local cand = (obj.candidates and obj.candidates[1]) or {}
  local parts = (cand.content and cand.content.parts) or {}
  local text, tool_calls = tools.gemini_parts_to_openai(parts)
  local um = obj.usageMetadata or {}

  local openai_obj = {
    id = "chatcmpl-gemini",
    object = "chat.completion",
    created = ngx.time(),
    model = client_model or obj.modelVersion,
    choices = {
      {
        index = 0,
        message = {
          role = "assistant",
          content = (text ~= "" and text) or (#tool_calls > 0 and nil or ""),
          tool_calls = #tool_calls > 0 and tool_calls or nil,
        },
        finish_reason = finish_reason(cand.finishReason, #tool_calls > 0),
      },
    },
    usage = {
      prompt_tokens = um.promptTokenCount or 0,
      completion_tokens = um.candidatesTokenCount or 0,
      total_tokens = um.totalTokenCount
        or ((um.promptTokenCount or 0) + (um.candidatesTokenCount or 0)),
    },
  }

  return status, headers, cjson.encode(openai_obj) or body
end


return _M
