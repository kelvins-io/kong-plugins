local cjson     = require "cjson.safe"
local router    = require "kong.plugins.ai-router.router"
local providers = require "kong.plugins.ai-router.providers"
local state     = require "kong.plugins.ai-router.state"
local http_client = require "kong.plugins.ai-router.http_client"
local models    = require "kong.plugins.ai-router.models"
local virtual_keys = require "kong.plugins.ai-router.virtual_keys"
local semantic  = require "kong.plugins.ai-router.semantic"
local errors    = require "kong.plugins.ai-router.errors"

local ngx = ngx
local kong = kong
local type = type
local ipairs = ipairs
local pairs = pairs
local tonumber = tonumber
local tostring = tostring
local floor = math.floor
local now = ngx.now
local sleep = ngx.sleep
local find = string.find
local lower = string.lower
local sub = string.sub


local _M = {}

local LOG_BODY_MAX = 200


local function request_id()
  local rid = ngx.var and ngx.var.request_id
  if type(rid) == "string" and rid ~= "" then
    return rid
  end
  return "-"
end


local function log_prefix()
  return "ai-router rid=" .. request_id()
end


local function truncate(s, max)
  max = max or LOG_BODY_MAX
  if type(s) ~= "string" then
    s = tostring(s or "")
  end
  if #s <= max then
    return s
  end
  return sub(s, 1, max) .. "..."
end


--- Prefer OpenAI-style error.message; otherwise truncate raw body.
local function extract_error_message(body)
  if type(body) ~= "string" or body == "" then
    return nil
  end
  local obj = cjson.decode(body)
  if type(obj) == "table" then
    if type(obj.error) == "table" and obj.error.message then
      return tostring(obj.error.message)
    end
    if type(obj.message) == "string" then
      return obj.message
    end
  end
  return body
end


local function log_final_failure(info)
  kong.log.warn(log_prefix(),
    " request failed",
    " status=", tostring(info.status or "-"),
    " model=", tostring(info.model or "-"),
    " provider=", tostring(info.provider or "-"),
    " deployment=", tostring(info.deployment or "-"),
    " attempts=", tostring(info.attempts or 0),
    " latency_ms=", tostring(info.latency_ms or "-"),
    " fallback_reason=", tostring(info.fallback_reason or "-"),
    " last_status=", tostring(info.last_status or "-"),
    " reason=", truncate(info.reason or ""))
end


local function path_matches(path, patterns)
  if not path then
    return false
  end
  for i = 1, #patterns do
    local p = patterns[i]
    if p and (path == p or sub(path, -#p) == p) then
      return true
    end
  end
  return false
end


local function detect_endpoint(path)
  path = lower(path or "")
  if find(path, "chat/completions", 1, true) then
    return "chat"
  end
  if find(path, "embeddings", 1, true) then
    return "embeddings"
  end
  if find(path, "completions", 1, true) then
    return "completions"
  end
  return "chat"
end


local function parse_body()
  local raw = kong.request.get_raw_body()
  if not raw or raw == "" then
    return nil, nil, "empty request body"
  end
  local body, err = cjson.decode(raw)
  if type(body) ~= "table" then
    return nil, raw, err or "request body is not JSON"
  end
  return body, raw
end


local function append_unique(chain, seen, list)
  if not list then
    return
  end
  for _, m in ipairs(list) do
    if m and not seen[m] then
      chain[#chain + 1] = m
      seen[m] = true
    end
  end
end


local function model_chain(conf, start_model, fb_map, request_fallbacks, disable_fallbacks)
  local chain = { start_model }
  local seen = { [start_model] = true }

  if disable_fallbacks then
    return chain
  end

  -- Request-level chain overrides plugin static fallbacks (LiteLLM client-side)
  if request_fallbacks and #request_fallbacks > 0 then
    append_unique(chain, seen, request_fallbacks)
    return chain
  end

  local list = fb_map[start_model]
  if (not list or #list == 0) and conf.default_fallbacks then
    list = conf.default_fallbacks
  end
  append_unique(chain, seen, list)
  return chain
end


--- Specialized fallback chain (context_window / content_policy): list only, no start model.
local function specialized_chain(list, seen_models)
  local chain = {}
  local seen = seen_models or {}
  append_unique(chain, seen, list)
  return chain
end


--- Parse LiteLLM-style request fallbacks; strip router-only fields from body.
--- Supports:
---   fallbacks: ["m2", "m3"] or [{model="m2"}, ...]
---   models: ["m2", "m3"]   (alias when array of strings)
---   disable_fallbacks: true
local function take_request_fallbacks(body)
  local disable = body.disable_fallbacks == true
  body.disable_fallbacks = nil

  local raw = body.fallbacks
  body.fallbacks = nil

  -- Alias: models as string array (not OpenAI standard; used by some gateways)
  if (not raw or type(raw) ~= "table" or #raw == 0)
     and type(body.models) == "table" and #body.models > 0 then
    local all_str = true
    for i = 1, #body.models do
      if type(body.models[i]) ~= "string" then
        all_str = false
        break
      end
    end
    if all_str then
      raw = body.models
      body.models = nil
    end
  end

  if disable then
    return {}, true
  end
  if type(raw) ~= "table" then
    return nil, false
  end

  local list = {}
  for i = 1, #raw do
    local item = raw[i]
    if type(item) == "string" and item ~= "" then
      list[#list + 1] = item
    elseif type(item) == "table" then
      local name = item.model or item.model_name
      if type(name) == "string" and name ~= "" then
        list[#list + 1] = name
      end
    end
  end
  if #list == 0 then
    return nil, false
  end
  return list, false
end


local function extract_usage(body)
  if type(body) ~= "string" then
    return 0, 0
  end
  local obj = cjson.decode(body)
  if type(obj) ~= "table" or type(obj.usage) ~= "table" then
    return 0, 0
  end
  return tonumber(obj.usage.prompt_tokens) or 0,
         tonumber(obj.usage.completion_tokens) or 0
end


local function diag_headers(conf, info)
  if not conf.response_headers then
    return {}
  end
  local h = {}
  if info.model then
    h["x-ai-router-model"] = info.model
  end
  if info.upstream_model then
    h["x-ai-router-upstream-model"] = info.upstream_model
  end
  if info.provider then
    h["x-ai-router-provider"] = info.provider
  end
  if info.deployment_id then
    h["x-ai-router-deployment"] = info.deployment_id
  end
  if info.attempts then
    h["x-ai-router-attempts"] = tostring(info.attempts)
  end
  if info.strategy then
    h["x-ai-router-strategy"] = info.strategy
  end
  if info.semantic_score then
    h["x-ai-router-semantic-score"] = string.format("%.4f", info.semantic_score)
  end
  if info.semantic_model then
    h["x-ai-router-semantic-model"] = info.semantic_model
  end
  if info.fallback_reason then
    h["x-ai-router-fallback-reason"] = info.fallback_reason
  end
  return h
end


local function merge_headers(...)
  local out = {}
  for i = 1, select("#", ...) do
    local t = select(i, ...)
    if type(t) == "table" then
      for k, v in pairs(t) do
        out[k] = v
      end
    end
  end
  return out
end


local function backoff(conf, attempt, err)
  -- Connect/SSL failures already burned connect_timeout; skip extra sleep.
  if http_client.is_connect_error(err) then
    return
  end
  local base = (conf.retry_after or 200) / 1000
  local cap = (conf.max_retry_backoff or 1000) / 1000
  if cap <= 0 then
    cap = 1
  end
  local t = base * (2 ^ (attempt - 1))
  if t > cap then
    t = cap
  end
  if t > 0 then
    sleep(t)
  end
end


local function retries_for(conf, stream)
  if stream then
    local n = conf.stream_num_retries
    if n == nil then
      n = 1
    end
    return n
  end
  return conf.num_retries or 2
end


--- Resolve connect/send/read timeouts (ms). Deployment overrides plugin defaults.
local function resolve_timeouts(conf, dep, req)
  local p = (dep and dep.litellm_params) or {}
  return {
    connect = p.connect_timeout or conf.connect_timeout or 2000,
    send = p.send_timeout or conf.send_timeout or 10000,
    read = (req and req.timeout) or p.timeout or conf.timeout or 60000,
  }
end


local function resolve_ssl_verify(conf, dep)
  local p = (dep and dep.litellm_params) or {}
  if p.ssl_verify ~= nil then
    return p.ssl_verify and true or false
  end
  if conf.ssl_verify ~= nil then
    return conf.ssl_verify and true or false
  end
  return true
end


local function http_opts(conf, dep)
  return {
    keepalive_timeout = conf.keepalive_timeout or 60000,
    keepalive_pool_size = conf.keepalive_pool_size or 128,
    ssl_verify = resolve_ssl_verify(conf, dep),
  }
end


--- opts.rpm_reserved: usage-based pre-incremented rpm; skip rpm in mark_success.
local function try_deployment(conf, dep, endpoint, body, client_model, stream, vk, opts)
  opts = opts or {}
  local rpm_reserved = opts.rpm_reserved == true
  local success_opts = { rpm_reserved = rpm_reserved }

  local req, err = providers.build_request(conf, dep, endpoint, body, client_model)
  if not req then
    return nil, err
  end

  local timeouts = resolve_timeouts(conf, dep, req)
  local ka = http_opts(conf, dep)
  state.incr_busy(conf, dep, 1)
  local t0 = now()

  local status, headers, resp_body, rerr

  if stream and req.stream then
    local streamed = false
    local usage
    status, headers, resp_body, usage = http_client.stream_request(req, timeouts, function(st, hdrs)
      streamed = true
      local out_headers = merge_headers(
        http_client.filter_response_headers(hdrs),
        diag_headers(conf, {
          model = client_model,
          upstream_model = req.upstream_model,
          provider = req.provider,
          deployment_id = state.deployment_id(dep),
          strategy = conf.routing_strategy,
        }),
        virtual_keys.budget_headers(conf, vk)
      )
      ngx.status = st
      for k, v in pairs(out_headers) do
        ngx.header[k] = v
      end
      ngx.header["Content-Length"] = nil
    end, ka)

    state.incr_busy(conf, dep, -1)
    local latency = floor((now() - t0) * 1000)

    if streamed then
      local pt = (usage and usage.prompt_tokens) or 0
      local ct = (usage and usage.completion_tokens) or 0
      state.mark_success(conf, dep, latency, pt, ct, success_opts)
      if conf.enable_virtual_keys then
        virtual_keys.charge(conf, vk, dep, pt, ct)
      end
      return {
        streamed = true,
        status = status,
        provider = req.provider,
        upstream_model = req.upstream_model,
        prompt_tokens = pt,
        completion_tokens = ct,
        dep = dep,
        rpm_reserved = rpm_reserved,
      }
    end

    if not status or http_client.is_retryable(status, resp_body) then
      state.mark_fail(conf, dep)
      local short_err = "stream failed"
      if status then
        short_err = "upstream status " .. tostring(status)
      elseif rerr then
        short_err = tostring(rerr)
      end
      return nil, short_err, status, resp_body, req, latency
    end
    return {
      status = status,
      headers = headers,
      body = resp_body,
      provider = req.provider,
      upstream_model = req.upstream_model,
      latency = latency,
      non_retryable = true,
      error_kind = errors.classify(status, resp_body),
      dep = dep,
      rpm_reserved = rpm_reserved,
    }
  end

  status, headers, resp_body, rerr = http_client.request(req, timeouts, ka)
  state.incr_busy(conf, dep, -1)
  local latency = floor((now() - t0) * 1000)

  if not status then
    state.mark_fail(conf, dep)
    return nil, rerr or "upstream error", nil, nil, req, latency
  end

  if status >= 200 and status < 300 then
    local pt, ct = extract_usage(resp_body)
    state.mark_success(conf, dep, latency, pt, ct, success_opts)
    status, headers, resp_body = providers.normalize_response(
      req.provider, endpoint, status, headers, resp_body, client_model, conf)
    -- re-extract after normalize (usage preserved)
    pt, ct = extract_usage(resp_body)
    return {
      status = status,
      headers = headers,
      body = resp_body,
      provider = req.provider,
      upstream_model = req.upstream_model,
      latency = latency,
      prompt_tokens = pt,
      completion_tokens = ct,
      dep = dep,
      rpm_reserved = rpm_reserved,
    }
  end

  if http_client.is_retryable(status, resp_body) then
    state.mark_fail(conf, dep)
    return nil, "upstream status " .. tostring(status), status, resp_body, req, latency
  end

  return {
    status = status,
    headers = headers,
    body = resp_body,
    provider = req.provider,
    upstream_model = req.upstream_model,
    latency = latency,
    non_retryable = true,
    error_kind = errors.classify(status, resp_body),
    dep = dep,
    rpm_reserved = rpm_reserved,
  }
end


function _M.execute(conf)
  local method = kong.request.get_method()
  local path = kong.request.get_path()

  -- /v1/models
  if conf.enable_models_endpoint and models.matches(path, method) then
    return models.handle(conf)
  end

  if method ~= "POST" then
    return
  end

  if not path_matches(path, conf.path_patterns or {}) then
    return
  end

  -- Virtual key auth
  local vk, verr, vstatus = virtual_keys.authenticate(conf)
  if conf.enable_virtual_keys then
    if verr then
      return kong.response.exit(vstatus or 401, {
        error = { message = verr, type = "authentication_error" },
      })
    end
    local ok_budget, spend, max_budget = virtual_keys.check_budget(conf, vk)
    if not ok_budget then
      kong.log.warn(log_prefix(),
        " budget exceeded spend=", tostring(spend),
        " max_budget=", tostring(max_budget))
      return kong.response.exit(429, {
        error = {
          message = "Budget exceeded: spend=" .. tostring(spend)
            .. " max_budget=" .. tostring(max_budget),
          type = "budget_exceeded",
        },
      }, virtual_keys.budget_headers(conf, vk, spend, max_budget))
    end
  end

  -- Global in-flight gate (released on all exit paths below)
  local inflight_held = false
  local function release_inflight()
    if inflight_held then
      state.release_inflight(conf)
      inflight_held = false
    end
  end

  local ok_inflight, inflight_n = state.try_acquire_inflight(conf)
  if not ok_inflight then
    kong.log.warn(log_prefix(),
      " max_inflight exceeded inflight=", tostring(inflight_n),
      " max=", tostring(conf.max_inflight))
    return kong.response.exit(429, {
      error = {
        message = "Too many in-flight AI requests: " .. tostring(inflight_n)
          .. " max_inflight=" .. tostring(conf.max_inflight),
        type = "rate_limit_error",
      },
    }, conf.response_headers and {
      ["x-ai-router-inflight"] = tostring(inflight_n),
      ["x-ai-router-max-inflight"] = tostring(conf.max_inflight),
    } or nil)
  end
  inflight_held = (tonumber(conf.max_inflight) or 0) > 0

  local function exit(status, body_or_json, headers)
    release_inflight()
    return kong.response.exit(status, body_or_json, headers)
  end

  local body, _, err = parse_body()
  if not body then
    return exit(400, {
      error = { message = err or "invalid JSON body", type = "invalid_request_error" },
    })
  end

  local request_fallbacks, disable_fallbacks = take_request_fallbacks(body)

  local client_model = body.model
  if type(client_model) ~= "string" or client_model == "" then
    return exit(400, {
      error = { message = "missing model", type = "invalid_request_error" },
    })
  end

  local requested_model = client_model
  local prompt_vec, semantic_score, prefer_dep
  local use_semantic = conf.routing_strategy == "semantic"
    or semantic.is_selector(conf, client_model)

  if use_semantic then
    local prompt_text = semantic.extract_prompt(body,
      (conf.semantic and conf.semantic.max_prompt_chars) or 4000)
    if prompt_text == "" then
      return exit(400, {
        error = {
          message = "semantic routing requires a non-empty prompt/messages",
          type = "invalid_request_error",
        },
      })
    end

    if semantic.is_selector(conf, client_model) then
      local allow_fn
      if conf.enable_virtual_keys then
        allow_fn = function(name)
          return virtual_keys.model_allowed(vk, name)
        end
      end
      local resolved, score, serr, pvec, pref =
        semantic.resolve_model(conf, conf.model_list, prompt_text, allow_fn)
      if not resolved then
        return exit(404, {
          error = {
            message = serr or "semantic routing found no matching model",
            type = "invalid_request_error",
            param = "model",
          },
        })
      end
      client_model = resolved
      semantic_score = score
      prompt_vec = pvec
      prefer_dep = pref
      body.model = client_model
    else
      local pvec, perr = semantic.embed(conf, prompt_text)
      if not pvec then
        kong.log.warn(log_prefix(),
          " semantic embed prompt failed: ", truncate(perr),
          "; falling back within model group")
      else
        prompt_vec = pvec
      end
    end
  end

  if conf.enable_virtual_keys and not virtual_keys.model_allowed(vk, client_model) then
    return exit(403, {
      error = {
        message = "model '" .. client_model .. "' not allowed for this API key",
        type = "permission_error",
        param = "model",
      },
    })
  end

  local groups = router.index_model_list(conf.model_list)
  if not groups[client_model] then
    return exit(404, {
      error = {
        message = "model '" .. client_model .. "' not found in model_list",
        type = "invalid_request_error",
        param = "model",
      },
    })
  end

  local endpoint = detect_endpoint(path)
  local stream = body.stream == true
  local fb_map = router.fallback_map(conf)
  local cw_map = router.context_window_fallback_map(conf)
  local cp_map = router.content_policy_fallback_map(conf)
  -- disable_fallbacks also blocks specialized context/content chains
  if disable_fallbacks then
    cw_map = {}
    cp_map = {}
  end
  local chain = model_chain(conf, client_model, fb_map, request_fallbacks, disable_fallbacks)
  local pick_opts = {
    prompt_vec = prompt_vec,
    prefer_dep = prefer_dep,
    semantic_score = semantic_score,
  }

  local exclude = {}
  local attempts = 0
  local last_status, last_body, last_headers
  local last_provider, last_upstream_model, last_deployment, last_latency, last_reason
  local special_kind = nil -- "context_window" | "content_policy" | nil
  local fallback_reason = (request_fallbacks and #request_fallbacks > 0) and "request" or nil
  local chain_seen = { [client_model] = true }
  local mi = 1
  local max_attempts = conf.max_attempts or 8
  local budget_exhausted = false

  while mi <= #chain do
    local model_name = chain[mi]
    local switched = false

    local model_ok = true
    if conf.enable_virtual_keys and not virtual_keys.model_allowed(vk, model_name) then
      model_ok = false
    end

    local deployments = model_ok and groups[model_name] or nil
    if deployments and #deployments > 0 then
      local retries_left = retries_for(conf, stream)
      local per_dep_retries = retries_left
      -- prefer_dep only applies to the first resolved model
      local opts = {
        prompt_vec = pick_opts.prompt_vec,
        prefer_dep = (model_name == client_model) and pick_opts.prefer_dep or nil,
        semantic_score = pick_opts.semantic_score,
      }

      while true do
        if attempts >= max_attempts then
          kong.log.debug(log_prefix(),
            " max_attempts=", max_attempts, " reached")
          budget_exhausted = true
          break
        end

        local dep, _, order, score, rpm_reserved = router.pick(conf, deployments, exclude, opts)
        if not dep then
          break
        end
        opts.prefer_dep = nil -- only once
        if score then
          semantic_score = score
        end

        attempts = attempts + 1
        local dep_id = state.deployment_id(dep)

        local result, rerr, st, rb, ureq, attempt_latency = try_deployment(
          conf, dep, endpoint, body, client_model, stream, vk,
          { rpm_reserved = rpm_reserved })

        if result and result.streamed then
          release_inflight()
          return ngx.exit(result.status or ngx.HTTP_OK)
        end

        if result and result.status and result.status >= 200 and result.status < 300 then
          local spend, max_budget
          if conf.enable_virtual_keys then
            local _, charged_spend = virtual_keys.charge(conf, vk, result.dep or dep,
              result.prompt_tokens, result.completion_tokens)
            spend = charged_spend
            if vk and not vk.is_master then
              max_budget = vk.max_budget
              if not spend then
                spend = state.get_spend(conf, vk.key)
              end
            end
          end
          local headers = merge_headers(
            http_client.filter_response_headers(result.headers),
            diag_headers(conf, {
              model = model_name,
              upstream_model = result.upstream_model,
              provider = result.provider,
              deployment_id = dep_id,
              attempts = attempts,
              strategy = use_semantic and "semantic" or conf.routing_strategy,
              semantic_score = semantic_score,
              semantic_model = requested_model ~= client_model and requested_model or nil,
              fallback_reason = fallback_reason,
            }),
            virtual_keys.budget_headers(conf, vk, spend, max_budget)
          )
          if not headers["Content-Type"] and not headers["content-type"] then
            headers["Content-Type"] = "application/json"
          end
          return exit(result.status, result.body, headers)
        end

        -- Failed attempt: roll back usage-based rpm reserve if any.
        if rpm_reserved then
          state.usage_release_reserve(conf, dep)
        end

        last_status = st or (result and result.status)
        last_body = rb or (result and result.body)
        last_headers = result and result.headers
        last_provider = (result and result.provider)
          or (ureq and ureq.provider)
          or last_provider
        last_upstream_model = (result and result.upstream_model)
          or (ureq and ureq.upstream_model)
          or last_upstream_model
        last_deployment = dep_id
        last_latency = (result and result.latency) or attempt_latency or last_latency
        exclude[dep_id] = true

        local kind = result and result.error_kind
        if not kind and result and result.non_retryable then
          kind = errors.classify(result.status, result.body)
        end
        if not kind and last_status and last_body then
          kind = errors.classify(last_status, last_body)
        end

        local body_msg = extract_error_message(last_body)
        local reason = rerr or "upstream error"
        if last_status and body_msg then
          reason = tostring(reason) .. ": " .. body_msg
        elseif not rerr and body_msg then
          reason = body_msg
        end
        last_reason = reason

        kong.log.debug(log_prefix(),
          " attempt failed model=", model_name,
          " provider=", tostring(last_provider or "-"),
          " upstream_model=", tostring(last_upstream_model or "-"),
          " dep=", dep_id,
          " order=", tostring(order),
          " latency_ms=", tostring(attempt_latency or (result and result.latency) or "-"),
          " err=", truncate(rerr or ""),
          " status=", tostring(last_status),
          " kind=", tostring(kind),
          " body=", truncate(body_msg or ""))

        local function continue_after_fail()
          if retries_left > 0 then
            retries_left = retries_left - 1
            backoff(conf, attempts, rerr)
            return true
          end
          local next_deps = router.next_order_deployments(
            deployments, order or 0, exclude, conf)
          if next_deps then
            retries_left = per_dep_retries
            backoff(conf, attempts, rerr)
            return true
          elseif router.pick(conf, deployments, exclude, { no_reserve = true }) then
            retries_left = per_dep_retries
            backoff(conf, attempts, rerr)
            return true
          end
          return false
        end

        -- Specialized fallbacks (LiteLLM-aligned)
        if kind == "context_window" or kind == "content_policy" then
          local map = (kind == "context_window") and cw_map or cp_map
          local special_list = map[model_name]
          if special_list and #special_list > 0 then
            chain_seen[model_name] = true
            local next_chain = specialized_chain(special_list, chain_seen)
            if #next_chain > 0 then
              kong.log.notice(log_prefix(), " ", kind, " fallback for model=", model_name,
                " -> ", table.concat(next_chain, ","))
              chain = next_chain
              mi = 1
              special_kind = kind
              fallback_reason = kind
              switched = true
              break
            end
          end

          -- Matching specialized chain already active and exhausted for this model:
          -- try next model in specialized chain (outer loop). If none left → return error.
          if special_kind == kind then
            break
          end

          -- No matching specialized rule: continue remaining order / generic fallbacks
          if not continue_after_fail() then
            break
          end
        elseif result and result.non_retryable then
          local out_status = result.status
          log_final_failure({
            status = out_status,
            model = model_name,
            provider = result.provider,
            deployment = dep_id,
            attempts = attempts,
            latency_ms = result.latency,
            fallback_reason = fallback_reason,
            last_status = out_status,
            reason = last_reason,
          })
          local headers = merge_headers(
            http_client.filter_response_headers(result.headers),
            diag_headers(conf, {
              model = model_name,
              upstream_model = result.upstream_model,
              provider = result.provider,
              deployment_id = dep_id,
              attempts = attempts,
              strategy = use_semantic and "semantic" or conf.routing_strategy,
              semantic_score = semantic_score,
              semantic_model = requested_model ~= client_model and requested_model or nil,
              fallback_reason = fallback_reason,
            }),
            virtual_keys.budget_headers(conf, vk)
          )
          if not headers["Content-Type"] and not headers["content-type"] then
            headers["Content-Type"] = "application/json"
          end
          return exit(out_status, result.body, headers)
        else
          if not continue_after_fail() then
            break
          end
        end
      end
    end

    if budget_exhausted then
      break
    end

    if not switched then
      mi = mi + 1
    end
  end

  local message = "All AI router deployments failed for model '" .. client_model .. "'"
  if budget_exhausted then
    message = message .. " (max_attempts=" .. tostring(max_attempts) .. ")"
  end
  local fb = fallback_reason or special_kind
  if last_body and type(last_body) == "string" and last_body ~= "" then
    local out_status = last_status or 503
    log_final_failure({
      status = out_status,
      model = client_model,
      provider = last_provider,
      deployment = last_deployment,
      attempts = attempts,
      latency_ms = last_latency,
      fallback_reason = fb,
      last_status = last_status,
      reason = last_reason or extract_error_message(last_body) or message,
    })
    local headers = merge_headers(
      http_client.filter_response_headers(last_headers),
      diag_headers(conf, {
        model = client_model,
        attempts = attempts,
        strategy = conf.routing_strategy,
        fallback_reason = fb,
      }),
      virtual_keys.budget_headers(conf, vk)
    )
    return exit(out_status, last_body, headers)
  end

  log_final_failure({
    status = 503,
    model = client_model,
    provider = last_provider,
    deployment = last_deployment,
    attempts = attempts,
    latency_ms = last_latency,
    fallback_reason = fb,
    last_status = last_status,
    reason = last_reason or message,
  })
  return exit(503, http_client.error_json(503, message, client_model),
    merge_headers(
      diag_headers(conf, {
        model = client_model,
        attempts = attempts,
        strategy = conf.routing_strategy,
        fallback_reason = fb,
      }),
      virtual_keys.budget_headers(conf, vk)
    ))
end


return _M
