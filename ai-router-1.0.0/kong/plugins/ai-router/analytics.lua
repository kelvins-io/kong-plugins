-- Request metrics for Kong log plugins (file-log / http-log) via set_serialize_value.
-- Aligns with Kong AI Proxy serialize-analytics shape under namespace `ai.router`.
local virtual_keys = require "kong.plugins.ai-router.virtual_keys"

local ngx = ngx
local kong = kong
local type = type
local tonumber = tonumber
local tostring = tostring
local floor = math.floor
local now = ngx.now


local _M = {}

local CTX_KEY = "ai_router_analytics"
local NAMESPACE = "router" -- → ai.router.meta / ai.router.usage


function _M.enabled(conf)
  return conf
    and conf.logging
    and conf.logging.log_statistics == true
end


local function ctx_bag()
  local bag = ngx.ctx[CTX_KEY]
  if type(bag) ~= "table" then
    bag = {
      started = false,
      t0 = nil,
      meta = {},
      usage = {},
    }
    ngx.ctx[CTX_KEY] = bag
  end
  return bag
end


--- Begin tracking for a handled request (path matched / models endpoint).
function _M.start(conf)
  if not _M.enabled(conf) then
    return
  end
  local bag = ctx_bag()
  if bag.started then
    return
  end
  bag.started = true
  bag.t0 = now()
  bag.meta = bag.meta or {}
  bag.usage = bag.usage or {}
  if conf.__plugin_id then
    bag.meta.plugin_id = conf.__plugin_id
  end
end


--- Merge fields into meta / usage. Unknown keys go to meta.
--- Recognized usage keys: prompt_tokens, completion_tokens, total_tokens,
---   cost, time_per_token, llm_latency (also copied to meta.llm_latency).
function _M.record(conf, fields)
  if not _M.enabled(conf) or type(fields) ~= "table" then
    return
  end
  _M.start(conf)
  local bag = ctx_bag()
  local meta = bag.meta
  local usage = bag.usage

  local function set_meta(k, v)
    if v ~= nil then
      meta[k] = v
    end
  end

  local function set_usage(k, v)
    if v ~= nil then
      usage[k] = v
    end
  end

  set_meta("plugin_id", fields.plugin_id or conf.__plugin_id)
  set_meta("provider_name", fields.provider or fields.provider_name)
  set_meta("request_model", fields.request_model or fields.requested_model)
  set_meta("response_model", fields.response_model or fields.model)
  set_meta("upstream_model", fields.upstream_model)
  set_meta("deployment", fields.deployment or fields.deployment_id)
  set_meta("attempts", fields.attempts)
  set_meta("strategy", fields.strategy)
  set_meta("semantic_score", fields.semantic_score)
  set_meta("semantic_model", fields.semantic_model)
  set_meta("fallback_reason", fields.fallback_reason)
  set_meta("endpoint", fields.endpoint)
  set_meta("stream", fields.stream)
  set_meta("status", fields.status)
  set_meta("key_name", fields.key_name)
  set_meta("success", fields.success)

  local latency = fields.llm_latency or fields.latency or fields.latency_ms
  if latency ~= nil then
    set_meta("llm_latency", latency)
    set_usage("llm_latency", latency)
  end

  set_usage("prompt_tokens", fields.prompt_tokens)
  set_usage("completion_tokens", fields.completion_tokens)
  set_usage("total_tokens", fields.total_tokens)
  set_usage("cost", fields.cost)
  set_usage("time_per_token", fields.time_per_token)
  set_usage("spend", fields.spend)
  set_usage("max_budget", fields.max_budget)
end


function _M.record_vk(conf, vk, spend, max_budget)
  if not _M.enabled(conf) or not vk then
    return
  end
  local fields = {
    key_name = vk.name or (vk.is_master and "master") or "default",
    spend = spend,
    max_budget = max_budget or vk.max_budget,
  }
  _M.record(conf, fields)
end


function _M.record_success(conf, info)
  if not _M.enabled(conf) then
    return
  end
  info = info or {}
  local pt = tonumber(info.prompt_tokens) or 0
  local ct = tonumber(info.completion_tokens) or 0
  local cost = tonumber(info.cost)
  if cost == nil and info.dep and info.vk then
    cost = virtual_keys.charge_amount(info.vk, info.dep, pt, ct)
  elseif cost == nil and info.dep then
    cost = virtual_keys.estimate_cost(info.dep, pt, ct)
  end

  _M.record(conf, {
    success = true,
    status = info.status or 200,
    provider = info.provider,
    request_model = info.request_model,
    model = info.model,
    response_model = info.model,
    upstream_model = info.upstream_model,
    deployment = info.deployment or info.deployment_id,
    attempts = info.attempts,
    strategy = info.strategy,
    semantic_score = info.semantic_score,
    semantic_model = info.semantic_model,
    fallback_reason = info.fallback_reason,
    endpoint = info.endpoint,
    stream = info.stream,
    latency_ms = info.latency or info.latency_ms,
    prompt_tokens = pt,
    completion_tokens = ct,
    total_tokens = pt + ct,
    cost = cost or 0,
    spend = info.spend,
    max_budget = info.max_budget,
    key_name = info.key_name,
  })
end


function _M.record_failure(conf, info)
  if not _M.enabled(conf) then
    return
  end
  info = info or {}
  _M.record(conf, {
    success = false,
    status = info.status,
    provider = info.provider,
    request_model = info.request_model,
    model = info.model,
    response_model = info.model,
    upstream_model = info.upstream_model,
    deployment = info.deployment or info.deployment_id,
    attempts = info.attempts,
    strategy = info.strategy,
    semantic_score = info.semantic_score,
    semantic_model = info.semantic_model,
    fallback_reason = info.fallback_reason,
    endpoint = info.endpoint,
    stream = info.stream,
    latency_ms = info.latency or info.latency_ms,
    prompt_tokens = info.prompt_tokens or 0,
    completion_tokens = info.completion_tokens or 0,
    total_tokens = (tonumber(info.prompt_tokens) or 0) + (tonumber(info.completion_tokens) or 0),
    cost = info.cost or 0,
    key_name = info.key_name,
  })
end


local function finalize(bag)
  local meta = bag.meta or {}
  local usage = bag.usage or {}

  -- e2e latency from start if per-attempt latency missing
  if bag.t0 and meta.llm_latency == nil then
    local ms = floor((now() - bag.t0) * 1000)
    if ms < 0 then
      ms = 0
    end
    meta.llm_latency = ms
    usage.llm_latency = ms
  elseif meta.llm_latency ~= nil and usage.llm_latency == nil then
    usage.llm_latency = meta.llm_latency
  end

  local pt = tonumber(usage.prompt_tokens) or 0
  local ct = tonumber(usage.completion_tokens) or 0
  usage.prompt_tokens = pt
  usage.completion_tokens = ct
  if usage.total_tokens == nil then
    usage.total_tokens = pt + ct
  end

  local latency = tonumber(usage.llm_latency) or tonumber(meta.llm_latency) or 0
  if usage.time_per_token == nil then
    if ct > 0 and latency > 0 then
      usage.time_per_token = latency / ct
    else
      usage.time_per_token = 0
    end
  end

  if usage.cost == nil then
    usage.cost = 0
  end

  -- normalize types for JSON logs
  if meta.attempts ~= nil then
    meta.attempts = tonumber(meta.attempts) or meta.attempts
  end
  if meta.semantic_score ~= nil then
    meta.semantic_score = tonumber(meta.semantic_score) or meta.semantic_score
  end
  if meta.status ~= nil then
    meta.status = tonumber(meta.status) or meta.status
  end

  return meta, usage
end


--- Write ai.router.meta / ai.router.usage into the Kong log serialize object.
--- Safe to call from access (before exit) and/or log phase.
function _M.serialize(conf)
  if not _M.enabled(conf) then
    return false
  end

  local bag = ngx.ctx[CTX_KEY]
  if type(bag) ~= "table" or not bag.started then
    return false
  end

  if type(kong.log.set_serialize_value) ~= "function" then
    return false
  end

  local meta, usage = finalize(bag)
  local prefix = "ai." .. NAMESPACE
  kong.log.set_serialize_value(prefix .. ".meta", meta)
  kong.log.set_serialize_value(prefix .. ".usage", usage)
  bag.serialized = true
  return true
end


--- log phase entry: serialize if not already done in access.
function _M.log(conf)
  return _M.serialize(conf)
end


-- test helpers
_M._CTX_KEY = CTX_KEY
_M._NAMESPACE = NAMESPACE
_M._finalize = finalize


return _M
