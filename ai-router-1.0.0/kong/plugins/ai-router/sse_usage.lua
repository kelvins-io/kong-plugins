-- Parse token usage from SSE / streaming chunks (OpenAI / Anthropic / Gemini-ish).
local cjson = require "cjson.safe"

local type = type
local tonumber = tonumber
local find = string.find
local sub = string.sub
local gsub = string.gsub


local _M = {}


local function apply_usage(state, usage)
  if type(usage) ~= "table" then
    return
  end
  local pt = tonumber(usage.prompt_tokens)
    or tonumber(usage.input_tokens)
    or tonumber(usage.promptTokenCount)
    or tonumber(usage.prompt_token_count)
  local ct = tonumber(usage.completion_tokens)
    or tonumber(usage.output_tokens)
    or tonumber(usage.candidatesTokenCount)
    or tonumber(usage.completion_token_count)
    or tonumber(usage.outputTokenCount)
  if pt then
    state.prompt_tokens = pt
  end
  if ct then
    state.completion_tokens = ct
  end
  local total = tonumber(usage.total_tokens) or tonumber(usage.totalTokenCount)
  if total and (not pt or not ct) and state.prompt_tokens and not state.completion_tokens then
    local rest = total - state.prompt_tokens
    if rest >= 0 then
      state.completion_tokens = rest
    end
  end
end


local function ingest_obj(state, obj)
  if type(obj) ~= "table" then
    return
  end

  if obj.usage then
    apply_usage(state, obj.usage)
  end
  if obj.usageMetadata then
    apply_usage(state, obj.usageMetadata)
  end

  -- Anthropic SSE event shapes
  if type(obj.message) == "table" and obj.message.usage then
    apply_usage(state, obj.message.usage)
  end
  if obj.type == "message_delta" and type(obj.usage) == "table" then
    apply_usage(state, obj.usage)
  end
  if obj.type == "message_start" and type(obj.message) == "table" then
    apply_usage(state, obj.message.usage)
  end
end


local function process_line(state, line)
  if not line or line == "" then
    return
  end
  -- strip leading "data:" (SSE) or "data: "
  local payload = line
  if find(payload, "^%s*data:%s*") then
    payload = gsub(payload, "^%s*data:%s*", "", 1)
  end
  payload = gsub(payload, "^%s+", "")
  payload = gsub(payload, "%s+$", "")
  if payload == "" or payload == "[DONE]" then
    return
  end
  local obj = cjson.decode(payload)
  ingest_obj(state, obj)
end


function _M.new()
  return {
    prompt_tokens = 0,
    completion_tokens = 0,
    _carry = "",
  }
end


--- Feed raw stream bytes; updates state.prompt_tokens / completion_tokens.
function _M.feed(state, chunk)
  if type(chunk) ~= "string" or chunk == "" then
    return
  end
  local buf = (state._carry or "") .. chunk
  local start = 1
  while true do
    local i = find(buf, "\n", start, true)
    if not i then
      break
    end
    local line = sub(buf, start, i - 1)
    line = gsub(line, "\r$", "")
    process_line(state, line)
    start = i + 1
  end
  state._carry = sub(buf, start)
end


function _M.finish(state)
  if state._carry and state._carry ~= "" then
    process_line(state, gsub(state._carry, "\r$", ""))
    state._carry = ""
  end
  return tonumber(state.prompt_tokens) or 0,
         tonumber(state.completion_tokens) or 0
end


return _M
