-- Classify upstream errors for LiteLLM-style specialized fallbacks.
local type = type
local find = string.find
local lower = string.lower


local _M = {}


local CONTEXT_SUBSTRINGS = {
  "exceed context limit",
  "this model's maximum context length is",
  "requested token count exceeds the model's maximum context length",
  "string too long. expected a string with maximum length",
  "model's maximum context limit",
  "is longer than the model's context length",
  "this is longer than the model's maximum context length",
  "input tokens exceed the configured limit",
  "`inputs` tokens + `max_new_tokens` must be",
  "exceeds the available context size",
  "exceeds the maximum number of tokens allowed",
  '"code": "context_length_exceeded"',
  "context_length_exceeded",
  "prompt is too long",
  "prompt tokens (",
  "exceed model maximum",
  "maximum context length",
  "context window",
}


local CONTENT_POLICY_SUBSTRINGS = {
  "content_policy_violation",
  "responsibleaipolicyviolation",
  "the response was filtered due to the prompt triggering azure openai's content management",
  "your task failed as a result of our safety system",
  "the model produced invalid content",
  "content_filter_policy",
  "your request was rejected as a result of our safety system",
  "content filtering policy",
  "content_filter",
  "content management policy",
  "blocked by the safety",
  "safety system",
  "usage policy",
}


local function has_any(haystack, needles)
  for i = 1, #needles do
    local n = needles[i]
    if find(haystack, n, 1, true) then
      return true
    end
  end
  return false
end


local function is_context_window(body_l)
  -- Exclude OpenAI "user" param max-length validation
  if find(body_l, "string_above_max_length", 1, true) then
    return false
  end
  if find(body_l, "invalid 'user'", 1, true) and find(body_l, "string too long", 1, true) then
    return false
  end

  if has_any(body_l, CONTEXT_SUBSTRINGS) then
    return true
  end
  if find(body_l, "current length is", 1, true) and find(body_l, "while limit is", 1, true) then
    return true
  end
  if find(body_l, "maximum input length is", 1, true) and find(body_l, "tokens", 1, true) then
    return true
  end
  if find(body_l, "input too long:", 1, true) and find(body_l, "input tokens, limit is", 1, true) then
    return true
  end
  return false
end


local function is_content_policy(body_l)
  if has_any(body_l, CONTENT_POLICY_SUBSTRINGS) then
    return true
  end
  if find(body_l, "invalid_request_error", 1, true)
     and find(body_l, "content_policy_violation", 1, true) then
    return true
  end
  return false
end


--- Returns "context_window" | "content_policy" | nil
function _M.classify(status, body)
  if type(body) ~= "string" or body == "" then
    return nil
  end
  -- These are typically 400; also accept 422 / 403 from some providers
  if status and status ~= 400 and status ~= 422 and status ~= 403 then
    return nil
  end

  local body_l = lower(body)

  -- Content policy first: some payloads mention both filters and length
  if is_content_policy(body_l) then
    return "content_policy"
  end
  if is_context_window(body_l) then
    return "context_window"
  end
  return nil
end


return _M
