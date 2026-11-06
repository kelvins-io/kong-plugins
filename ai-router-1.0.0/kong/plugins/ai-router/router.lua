-- LiteLLM-aligned deployment selection.
local state = require "kong.plugins.ai-router.state"
local semantic = require "kong.plugins.ai-router.semantic"

local ipairs = ipairs
local type = type
local tonumber = tonumber
local random = math.random
local huge = math.huge
local sort = table.sort


local _M = {}


local function params(dep)
  return dep.litellm_params or dep
end


local function weight_of(dep)
  local p = params(dep)
  if p.rpm and p.rpm > 0 then
    return p.rpm
  end
  if p.tpm and p.tpm > 0 then
    -- rough: Azure ~6 RPM per 1000 TPM
    return p.tpm / 1000 * 6
  end
  return tonumber(p.weight) or 1
end


local function cost_of(dep)
  local p = params(dep)
  local cin = tonumber(p.input_cost_per_token) or 0
  local cout = tonumber(p.output_cost_per_token) or 0
  if cin <= 0 and cout <= 0 then
    return huge
  end
  return cin + cout
end


local function filter_available(conf, deployments, exclude)
  -- One Redis MGET for cooldown/busy/latency/usage of the whole candidate set.
  state.prefetch(conf, deployments)

  local out = {}
  for i = 1, #deployments do
    local dep = deployments[i]
    local id = state.deployment_id(dep)
    if not (exclude and exclude[id]) then
      if not conf.enable_pre_call_checks or not state.is_cooled(conf, dep) then
        out[#out + 1] = dep
      end
    end
  end
  return out
end


local function group_by_order(deployments)
  local by_order = {}
  local orders = {}
  for i = 1, #deployments do
    local dep = deployments[i]
    local o = tonumber(params(dep).order) or 1
    if not by_order[o] then
      by_order[o] = {}
      orders[#orders + 1] = o
    end
    by_order[o][#by_order[o] + 1] = dep
  end
  sort(orders)
  return by_order, orders
end


local function simple_shuffle(candidates)
  if #candidates == 0 then
    return nil
  end
  if #candidates == 1 then
    return candidates[1]
  end

  local total = 0
  local weights = {}
  for i = 1, #candidates do
    local w = weight_of(candidates[i])
    if w < 0 then
      w = 0
    end
    weights[i] = w
    total = total + w
  end

  if total <= 0 then
    return candidates[random(1, #candidates)]
  end

  local r = random() * total
  local acc = 0
  for i = 1, #candidates do
    acc = acc + weights[i]
    if r <= acc then
      return candidates[i]
    end
  end
  return candidates[#candidates]
end


local function least_busy(conf, candidates)
  local best, best_busy
  for i = 1, #candidates do
    local b = state.get_busy(conf, candidates[i])
    if not best or b < best_busy then
      best = candidates[i]
      best_busy = b
    end
  end
  return best
end


local function latency_based(conf, candidates)
  local best, best_lat
  local unknown = {}
  for i = 1, #candidates do
    local lat = state.get_latency(conf, candidates[i])
    if not lat then
      unknown[#unknown + 1] = candidates[i]
    elseif not best or lat < best_lat then
      best = candidates[i]
      best_lat = lat
    end
  end
  -- explore unknown first (LiteLLM-like warm-up)
  if #unknown > 0 then
    return simple_shuffle(unknown)
  end
  return best
end


local function cost_based(candidates)
  local best, best_cost
  for i = 1, #candidates do
    local c = cost_of(candidates[i])
    if not best or c < best_cost then
      best = candidates[i]
      best_cost = c
    end
  end
  return best
end


local function usage_based(conf, candidates)
  -- Prefer deployments furthest from rpm/tpm ceiling; skip those over limit.
  local eligible = {}
  for i = 1, #candidates do
    local dep = candidates[i]
    local p = params(dep)
    local rpm, tpm = state.get_usage(conf, dep)
    local over = false
    if p.rpm and rpm >= p.rpm then
      over = true
    end
    if p.tpm and tpm >= p.tpm then
      over = true
    end
    if not over then
      eligible[#eligible + 1] = { dep = dep, rpm = rpm, tpm = tpm, p = p }
    end
  end

  if #eligible == 0 then
    return simple_shuffle(candidates)
  end

  local best, best_score
  for i = 1, #eligible do
    local e = eligible[i]
    local rpm_ratio = e.p.rpm and (e.rpm / e.p.rpm) or 0
    local tpm_ratio = e.p.tpm and (e.tpm / e.p.tpm) or 0
    local score = rpm_ratio > tpm_ratio and rpm_ratio or tpm_ratio
    if not best or score < best_score then
      best = e.dep
      best_score = score
    end
  end
  return best
end


function _M.index_model_list(model_list)
  local groups = {}
  for i = 1, #(model_list or {}) do
    local entry = model_list[i]
    local name = entry.model_name
    if name then
      if not groups[name] then
        groups[name] = {}
      end
      groups[name][#groups[name] + 1] = entry
    end
  end
  return groups
end


local function rules_to_map(rules)
  local map = {}
  for i = 1, #(rules or {}) do
    local rule = rules[i]
    if rule and rule.model and type(rule.fallbacks) == "table" then
      map[rule.model] = rule.fallbacks
    end
  end
  return map
end


function _M.fallback_map(conf)
  return rules_to_map(conf.fallbacks)
end


function _M.context_window_fallback_map(conf)
  return rules_to_map(conf.context_window_fallbacks)
end


function _M.content_policy_fallback_map(conf)
  return rules_to_map(conf.content_policy_fallbacks)
end


--- opts.prompt_vec: embedding vector for semantic strategy
--- opts.prefer_dep: preferred deployment to try first (from cross-model resolve)
--- opts.semantic_score: score from cross-model resolve (returned with prefer_dep)
function _M.pick(conf, deployments, exclude, opts)
  opts = opts or {}
  local available = filter_available(conf, deployments, exclude)
  if #available == 0 then
    return nil, "no available deployments"
  end

  if opts.prefer_dep then
    local pid = state.deployment_id(opts.prefer_dep)
    for i = 1, #available do
      if state.deployment_id(available[i]) == pid then
        return available[i], nil, tonumber(params(available[i]).order) or 1, opts.semantic_score
      end
    end
  end

  local by_order, orders = group_by_order(available)
  for _, o in ipairs(orders) do
    local candidates = by_order[o]
    local strategy = conf.routing_strategy or "simple-shuffle"
    local chosen
    local score

    if strategy == "least-busy" then
      chosen = least_busy(conf, candidates)
    elseif strategy == "latency-based-routing" then
      chosen = latency_based(conf, candidates)
    elseif strategy == "cost-based-routing" then
      chosen = cost_based(candidates)
    elseif strategy == "usage-based-routing" then
      chosen = usage_based(conf, candidates)
    elseif strategy == "semantic" then
      if opts.prompt_vec then
        chosen, score = semantic.pick_best(conf, candidates, opts.prompt_vec)
      end
      if not chosen then
        chosen = simple_shuffle(candidates)
      end
    else
      chosen = simple_shuffle(candidates)
    end

    if chosen then
      return chosen, nil, o, score
    end
  end

  return nil, "no available deployments"
end


function _M.next_order_deployments(deployments, after_order, exclude, conf)
  local available = filter_available(conf, deployments, exclude)
  local by_order, orders = group_by_order(available)
  for _, o in ipairs(orders) do
    if o > after_order then
      return by_order[o], o
    end
  end
  return nil
end


return _M
