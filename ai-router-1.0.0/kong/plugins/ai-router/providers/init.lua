local openai    = require "kong.plugins.ai-router.providers.openai"
local azure     = require "kong.plugins.ai-router.providers.azure"
local anthropic = require "kong.plugins.ai-router.providers.anthropic"
local bedrock   = require "kong.plugins.ai-router.providers.bedrock"
local gemini    = require "kong.plugins.ai-router.providers.gemini"

local type = type
local find = string.find
local sub = string.sub
local tostring = tostring


local _M = {}


-- OpenAI-compatible vendor defaults (LiteLLM-style prefixes).
local COMPAT_DEFAULT_BASE = {
  openai    = "https://api.openai.com/v1",
  groq      = "https://api.groq.com/openai/v1",
  mistral   = "https://api.mistral.ai/v1",
  deepseek  = "https://api.deepseek.com/v1",
  cohere    = "https://api.cohere.ai/compatibility/v1",
  together_ai = "https://api.together.xyz/v1",
  together  = "https://api.together.xyz/v1",
  openrouter = "https://openrouter.ai/api/v1",
  fireworks_ai = "https://api.fireworks.ai/inference/v1",
  fireworks = "https://api.fireworks.ai/inference/v1",
}

local DEFAULT_BASE = {
  openai    = COMPAT_DEFAULT_BASE.openai,
  anthropic = "https://api.anthropic.com",
  gemini    = "https://generativelanguage.googleapis.com/v1beta",
  vertex_ai = "https://generativelanguage.googleapis.com/v1beta",
}


local adapters = {
  openai    = openai,
  azure     = azure,
  anthropic = anthropic,
  bedrock   = bedrock,
  gemini    = gemini,
}


function _M.parse_model(model_str)
  if type(model_str) ~= "string" or model_str == "" then
    return nil, nil, "empty model"
  end

  local slash = find(model_str, "/", 1, true)
  if not slash then
    return "openai", model_str
  end

  local provider = sub(model_str, 1, slash - 1):lower()
  local rest = sub(model_str, slash + 1)
  if provider == "" or rest == "" then
    return nil, nil, "invalid model string: " .. model_str
  end

  if provider == "azure" or provider == "azure_ai" then
    return "azure", rest
  end
  if provider == "anthropic" or provider == "claude" then
    return "anthropic", rest
  end
  if provider == "bedrock" or provider == "bedrock_converse" then
    return "bedrock", rest
  end
  if provider == "gemini" or provider == "vertex_ai" or provider == "google" then
    return "gemini", rest
  end
  if provider == "openai" or provider == "openai_compatible" then
    return "openai", rest, nil, "openai"
  end

  -- OpenAI-compatible vendors: keep vendor tag for default api_base
  if COMPAT_DEFAULT_BASE[provider] then
    return "openai", rest, nil, provider
  end

  -- unknown prefix: treat whole string as openai-compatible model name
  return "openai", model_str
end


function _M.resolve(dep)
  local p = dep.litellm_params or {}
  local provider, upstream_model, err, compat_vendor = _M.parse_model(p.model)
  if not provider then
    return nil, err
  end

  local api_base = p.api_base
  if (not api_base or api_base == "") then
    if provider == "openai" and compat_vendor and COMPAT_DEFAULT_BASE[compat_vendor] then
      api_base = COMPAT_DEFAULT_BASE[compat_vendor]
    elseif provider ~= "azure" and provider ~= "bedrock" then
      api_base = DEFAULT_BASE[provider]
    end
  end

  if provider == "azure" and (not api_base or api_base == "") then
    return nil, "azure deployment requires api_base"
  end

  return {
    provider = provider,
    upstream_model = upstream_model,
    api_base = api_base,
    api_key = p.api_key,
    api_version = p.api_version or "2024-02-15-preview",
    organization = p.organization,
    extra_headers = p.extra_headers,
    max_tokens = p.max_tokens,
    temperature = p.temperature,
    timeout = p.timeout,
    connect_timeout = p.connect_timeout,
    send_timeout = p.send_timeout,
    aws_region_name = p.aws_region_name or p.aws_region,
    aws_region = p.aws_region or p.aws_region_name,
  }
end


function _M.adapter(provider)
  return adapters[provider]
end


function _M.build_request(conf, dep, endpoint, client_body, client_model)
  local resolved, err = _M.resolve(dep)
  if not resolved then
    return nil, err
  end

  local adapter = adapters[resolved.provider]
  if not adapter then
    return nil, "unsupported provider: " .. tostring(resolved.provider)
  end

  return adapter.build(conf, resolved, endpoint, client_body, client_model)
end


function _M.normalize_response(provider, endpoint, status, headers, body, client_model, conf)
  local adapter = adapters[provider]
  if adapter and adapter.normalize_response then
    return adapter.normalize_response(endpoint, status, headers, body, client_model, conf)
  end
  return status, headers, body
end


return _M
