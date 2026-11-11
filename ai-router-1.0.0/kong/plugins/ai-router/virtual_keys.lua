-- Virtual keys + budget (LiteLLM-style sk-... keys configured in plugin).
local state = require "kong.plugins.ai-router.state"

local kong = kong
local type = type
local ipairs = ipairs
local tonumber = tonumber
local tostring = tostring
local sub = string.sub


local _M = {}


--- Prefer key name; never log the full virtual key secret.
local function key_label(vk)
  if not vk then
    return "-"
  end
  if type(vk.name) == "string" and vk.name ~= "" then
    return vk.name
  end
  local k = vk.key or ""
  if type(k) ~= "string" or k == "" then
    return "-"
  end
  if #k <= 6 then
    return "key(len=" .. tostring(#k) .. ")"
  end
  return sub(k, 1, 6) .. "...(len=" .. tostring(#k) .. ")"
end


local function extract_bearer()
  local auth = kong.request.get_header("authorization")
    or kong.request.get_header("Authorization")
  if type(auth) == "table" then
    auth = auth[1]
  end
  if type(auth) ~= "string" or auth == "" then
    local alt = kong.request.get_header("x-api-key")
      or kong.request.get_header("X-API-KEY")
    if type(alt) == "table" then
      alt = alt[1]
    end
    return alt
  end
  local m = auth:match("^[Bb]earer%s+(.+)$")
  return m or auth
end


function _M.index(conf)
  local map = {}
  for _, vk in ipairs(conf.virtual_keys or {}) do
    if vk and vk.key then
      map[vk.key] = vk
    end
  end
  return map
end


--- Returns virtual_key record or nil, err, status
function _M.authenticate(conf)
  if not conf.enable_virtual_keys then
    return nil -- disabled
  end

  local token = extract_bearer()
  if not token or token == "" then
    return nil, "missing API key", 401
  end

  -- master key bypass
  if conf.master_key and conf.master_key ~= "" and token == conf.master_key then
    return {
      key = token,
      name = "master",
      is_master = true,
      models = nil, -- all
      max_budget = nil,
    }
  end

  local map = _M.index(conf)
  local vk = map[token]
  if not vk then
    return nil, "invalid API key", 401
  end
  if vk.blocked then
    return nil, "API key blocked", 403
  end
  return vk
end


function _M.model_allowed(vk, model)
  if not vk or vk.is_master then
    return true
  end
  local models = vk.models
  if not models or #models == 0 then
    return true
  end
  for i = 1, #models do
    if models[i] == model or models[i] == "*" then
      return true
    end
    -- prefix wildcard: gpt-*
    local pat = models[i]
    if type(pat) == "string" and sub(pat, -1) == "*" then
      local prefix = sub(pat, 1, -2)
      if sub(model, 1, #prefix) == prefix then
        return true
      end
    end
  end
  return false
end


--- Pre-flight gate using the same atomic path as charge (spend_lock / Redis EVAL).
function _M.check_budget(conf, vk)
  if not vk or vk.is_master then
    return true
  end
  local max_budget = tonumber(vk.max_budget)
  if not max_budget or max_budget <= 0 then
    return true
  end
  local ok, spend, err = state.budget_admit(conf, vk.key, max_budget)
  if not ok then
    return false, spend, max_budget, err
  end
  return true, spend, max_budget
end


function _M.estimate_cost(dep, prompt_tokens, completion_tokens)
  local p = (dep and dep.litellm_params) or {}
  local cin = tonumber(p.input_cost_per_token) or 0
  local cout = tonumber(p.output_cost_per_token) or 0
  local cost = (prompt_tokens or 0) * cin + (completion_tokens or 0) * cout
  return cost
end


--- Compute charge amount (provider costs, else token_cost fallback).
function _M.charge_amount(vk, dep, prompt_tokens, completion_tokens)
  if not vk or vk.is_master then
    return 0
  end
  local cost = _M.estimate_cost(dep, prompt_tokens, completion_tokens)
  if cost <= 0 then
    local token_cost = tonumber(vk.token_cost) or 0
    cost = ((prompt_tokens or 0) + (completion_tokens or 0)) * token_cost
  end
  return cost
end


--- Atomic charge against max_budget.
--- Returns ok, spend, err ("budget_exceeded" when blocked)
function _M.charge(conf, vk, dep, prompt_tokens, completion_tokens)
  if not vk or vk.is_master then
    return true, nil
  end
  local cost = _M.charge_amount(vk, dep, prompt_tokens, completion_tokens)
  if cost <= 0 then
    return true, state.get_spend(conf, vk.key)
  end

  local max_budget = tonumber(vk.max_budget) or 0
  local ok, spend, err = state.try_add_spend(conf, vk.key, cost, max_budget)
  if not ok then
    kong.log.warn("ai-router budget charge denied key=", key_label(vk),
      " cost=", tostring(cost), " spend=", tostring(spend), " err=", tostring(err))
    return false, spend, err or "budget_exceeded"
  end
  return true, spend
end


function _M.budget_headers(conf, vk, spend, max_budget)
  if not conf.response_headers or not vk or vk.is_master then
    return {}
  end
  local h = {
    ["x-ai-router-key-name"] = vk.name or "default",
  }
  if spend then
    h["x-ai-router-spend"] = tostring(spend)
  end
  if max_budget then
    h["x-ai-router-max-budget"] = tostring(max_budget)
  end
  return h
end


return _M
