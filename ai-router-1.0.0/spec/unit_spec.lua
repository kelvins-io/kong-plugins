-- Standalone unit tests (no Kong/OpenResty required).
-- Run from plugin root:
--   lua spec/unit_spec.lua

local here = arg and arg[0] and arg[0]:match("(.*/)") or "./"
local root = here .. "../"
package.path = root .. "?.lua;" .. root .. "?/init.lua;" .. package.path

-- Stubs for OpenResty / resty modules touched at require-time.
_G.ngx = {
  null = {},
  now = function() return os.time() end,
  sleep = function() end,
  shared = {},
  ctx = {},
  re = { match = function() return nil end },
  log = function() end,
  print = function() end,
  flush = function() end,
  ERR = 1, WARN = 2, NOTICE = 3, INFO = 4,
  escape_uri = function(s) return s end,
  md5 = function(s) return s end,
}
_G.kong = {
  log = {
    warn = function() end,
    notice = function() end,
    info = function() end,
    debug = function() end,
    err = function() end,
    set_serialize_value = function() end,
  },
}

package.preload["resty.http"] = function()
  return {
    new = function()
      return {
        set_timeouts = function() end,
        set_timeout = function() end,
        set_keepalive = function() return true end,
        connect = function() return true end,
        ssl_handshake = function() return true end,
        request = function() return nil, "stub" end,
        request_uri = function() return nil, "stub" end,
        close = function() end,
      }
    end,
  }
end

package.preload["resty.redis"] = function()
  return {
    new = function()
      return {
        set_timeout = function() end,
        connect = function() return true end,
        get_reused_times = function() return 1 end,
        set_keepalive = function() return true end,
        get = function() return ngx.null end,
        mget = function() return {} end,
        set = function() return true end,
        setex = function() return true end,
        del = function() return true end,
        incrby = function() return 1 end,
        incrbyfloat = function() return 1 end,
        expire = function() return true end,
        exists = function() return 0 end,
        init_pipeline = function() end,
        commit_pipeline = function() return { 1 } end,
        eval = function() return { 0, 1 } end,
        auth = function() return true end,
        select = function() return true end,
        close = function() end,
      }
    end,
  }
end

package.preload["cjson.safe"] = function()
  local ok, cjson = pcall(require, "cjson")
  if ok then
    return cjson
  end
  return {
    encode = function(t) return tostring(t) end,
    decode = function(s)
      if s:find("prompt_tokens") then
        return { usage = { prompt_tokens = 3, completion_tokens = 7 } }
      end
      if s:find("context_length_exceeded") then
        return { error = { code = "context_length_exceeded" } }
      end
      return {}
    end,
  }
end


local failures = 0
local passes = 0

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    failures = failures + 1
    io.stderr:write(string.format("FAIL %s: got (%s) expected (%s)\n",
      msg or "", tostring(actual), tostring(expected)))
    return
  end
  passes = passes + 1
end

local function assert_true(v, msg)
  assert_eq(not not v, true, msg)
end

local function assert_false(v, msg)
  assert_eq(not not v, false, msg)
end


-- ---- http_client ----
do
  local http_client = require "kong.plugins.ai-router.http_client"

  local c, s, r = http_client.normalize_timeouts(nil)
  assert_eq(c, 2000, "default connect")
  assert_eq(s, 10000, "default send")
  assert_eq(r, 60000, "default read")

  c, s, r = http_client.normalize_timeouts(12000)
  assert_eq(r, 12000, "number as read")

  c, s, r = http_client.normalize_timeouts({
    connect_timeout = 500,
    send_timeout = 1500,
    timeout = 9000,
  })
  assert_eq(c, 500, "table connect")
  assert_eq(s, 1500, "table send")
  assert_eq(r, 9000, "table read")

  assert_true(http_client.is_connect_error("connect failed: timeout"), "connect err")
  assert_true(http_client.is_connect_error("ssl handshake failed: x"), "ssl err")
  assert_false(http_client.is_connect_error("upstream status 500"), "not connect")

  assert_true(http_client.is_retryable(nil), "nil status retryable")
  assert_true(http_client.is_retryable(429), "429 retryable")
  assert_true(http_client.is_retryable(503), "503 retryable")
  assert_false(http_client.is_retryable(400), "400 not retryable")
  assert_true(http_client.is_retryable(400, "please try again later"), "400 overloaded")
end


-- ---- errors ----
do
  local errors = require "kong.plugins.ai-router.errors"
  assert_eq(errors.classify(400, '{"code": "context_length_exceeded"}'),
    "context_window", "context window code")
  assert_eq(errors.classify(400, "maximum context length is 8192"),
    "context_window", "context phrase")
  assert_eq(errors.classify(400, "content_policy_violation"),
    "content_policy", "content policy")
  assert_eq(errors.classify(400, "blocked by the safety system"),
    "content_policy", "safety")
  assert_eq(errors.classify(400, "invalid temperature"), nil, "generic 400")
end


-- ---- budget decision ----
do
  local state = require "kong.plugins.ai-router.state"

  local ok, neu = state.budget_charge_decision(9.5, 0.6, 10)
  assert_false(ok, "over budget blocked")
  assert_eq(neu, 9.5, "spend unchanged")

  ok, neu = state.budget_charge_decision(9.5, 0.4, 10)
  assert_true(ok, "within budget")
  -- float compare
  assert_true(math.abs(neu - 9.9) < 1e-9, "spend updated")

  ok, neu = state.budget_charge_decision(5, 100, 0)
  assert_true(ok, "unlimited budget")
  assert_eq(neu, 105, "unlimited add")

  ok, neu = state.budget_charge_decision(10, 0, 10)
  assert_true(ok, "zero cost ok")
  assert_eq(neu, 10, "zero cost spend")
end


-- ---- virtual_keys ----
do
  local vk_mod = require "kong.plugins.ai-router.virtual_keys"

  assert_true(vk_mod.model_allowed({ models = {} }, "any"), "empty allow all")
  assert_true(vk_mod.model_allowed({ models = { "gpt-4o" } }, "gpt-4o"), "exact")
  assert_false(vk_mod.model_allowed({ models = { "gpt-4o" } }, "claude"), "deny")
  assert_true(vk_mod.model_allowed({ models = { "gpt-*" } }, "gpt-4o-mini"), "wildcard")
  assert_true(vk_mod.model_allowed({ is_master = true, models = { "x" } }, "y"), "master")

  local cost = vk_mod.estimate_cost({
    litellm_params = { input_cost_per_token = 0.01, output_cost_per_token = 0.02 },
  }, 10, 5)
  assert_true(math.abs(cost - 0.2) < 1e-9, "estimate_cost")

  local amount = vk_mod.charge_amount({
    token_cost = 0.001,
  }, { litellm_params = {} }, 100, 50)
  assert_true(math.abs(amount - 0.15) < 1e-9, "token_cost fallback")
end


-- ---- router ----
do
  local router = require "kong.plugins.ai-router.router"

  local groups = router.index_model_list({
    { model_name = "a", litellm_params = { model = "openai/a" } },
    { model_name = "a", litellm_params = { model = "openai/a2" } },
    { model_name = "b", litellm_params = { model = "openai/b" } },
  })
  assert_eq(#groups.a, 2, "group a size")
  assert_eq(#groups.b, 1, "group b size")

  local fb = router.fallback_map({
    fallbacks = {
      { model = "a", fallbacks = { "b", "c" } },
    },
  })
  assert_eq(fb.a[1], "b", "fallback first")
  assert_eq(#fb.a, 2, "fallback len")
end


-- ---- usage lock (local shdict) ----
do
  local store = {}
  local function mock_dict()
    return {
      add = function(_, k, v, ttl)
        if store[k] ~= nil then
          return false, "exists"
        end
        store[k] = { v = v, ttl = ttl }
        return true
      end,
      get = function(_, k)
        local e = store[k]
        return e and e.v or nil
      end,
      set = function(_, k, v, ttl)
        store[k] = { v = v, ttl = ttl }
        return true
      end,
      delete = function(_, k)
        store[k] = nil
        return true
      end,
      incr = function(_, k, delta, init, ttl)
        local e = store[k]
        local cur = e and tonumber(e.v) or (init or 0)
        cur = cur + delta
        store[k] = { v = cur, ttl = ttl }
        return cur
      end,
    }
  end
  ngx.shared.ai_router = mock_dict()

  local state = require "kong.plugins.ai-router.state"
  local conf = { state_backend = "local", shared_dict = "ai_router" }
  local dep = {
    model_name = "gpt-4o",
    litellm_params = { model = "openai/gpt-4o", order = 1 },
  }
  local id = state.deployment_id(dep)

  assert_true(state.acquire_usage_lock(conf, id), "usage lock acquire")
  assert_false(state.acquire_usage_lock(conf, id), "usage lock held blocks")
  state.release_usage_lock(conf, id)
  assert_true(state.acquire_usage_lock(conf, id), "usage lock reacquire")
  state.release_usage_lock(conf, id)

  state.mark_success(conf, dep, 100, 10, 20)
  local minute = math.floor(ngx.now() / 60)
  local rpm_key = "rpm:" .. id .. ":" .. minute
  local tpm_key = "tpm:" .. id .. ":" .. minute
  assert_eq(tonumber(store[rpm_key] and store[rpm_key].v), 1, "mark_success rpm")
  assert_eq(tonumber(store[tpm_key] and store[tpm_key].v), 30, "mark_success tpm")

  local rpm, tpm = state.get_usage(conf, dep, { locked = true })
  assert_eq(rpm, 1, "locked get_usage rpm")
  assert_eq(tpm, 30, "locked get_usage tpm")
  assert_eq(store["usage_lock:" .. id], nil, "lock released after get_usage")

  -- usage reserve / release
  store = {}
  ngx.shared.ai_router = mock_dict()
  local dep_lim = {
    model_name = "gpt-4o",
    litellm_params = { model = "openai/gpt-4o", order = 1, rpm = 2, tpm = 1000 },
  }
  local id2 = state.deployment_id(dep_lim)
  local ok_r, reserved = state.usage_try_reserve(conf, dep_lim)
  assert_true(ok_r, "reserve ok")
  assert_true(reserved, "reserved flag")
  assert_eq(tonumber(store["rpm:" .. id2 .. ":" .. minute] and store["rpm:" .. id2 .. ":" .. minute].v), 1, "reserve rpm")
  state.mark_success(conf, dep_lim, 50, 5, 5, { rpm_reserved = true })
  assert_eq(tonumber(store["rpm:" .. id2 .. ":" .. minute].v), 1, "no double rpm on success")
  assert_eq(tonumber(store["tpm:" .. id2 .. ":" .. minute].v), 10, "tpm added")

  ok_r, reserved = state.usage_try_reserve(conf, dep_lim)
  assert_true(ok_r, "second reserve")
  state.usage_release_reserve(conf, dep_lim)
  assert_eq(tonumber(store["rpm:" .. id2 .. ":" .. minute].v), 1, "release rolled back")

  -- fill rpm to ceiling
  state.usage_try_reserve(conf, dep_lim) -- rpm=2
  ok_r = state.usage_try_reserve(conf, dep_lim)
  assert_false(ok_r, "reserve blocked at rpm ceiling")

  -- budget_admit under spend_lock
  store = {}
  ngx.shared.ai_router = mock_dict()
  store["spend:k1"] = { v = 10 }
  local ok_b, sp = state.budget_admit(conf, "k1", 10)
  assert_false(ok_b, "admit denied at ceiling")
  assert_eq(sp, 10, "admit spend")
  store["spend:k1"] = { v = 9 }
  ok_b, sp = state.budget_admit(conf, "k1", 10)
  assert_true(ok_b, "admit under ceiling")
  assert_eq(sp, 9, "admit current spend")

  -- inflight lock acquire
  store = {}
  ngx.shared.ai_router = mock_dict()
  local ok_i, n = state.try_acquire_inflight({ state_backend = "local", shared_dict = "ai_router", max_inflight = 1 })
  assert_true(ok_i, "inflight first")
  assert_eq(n, 1, "inflight n")
  ok_i, n = state.try_acquire_inflight({ state_backend = "local", shared_dict = "ai_router", max_inflight = 1 })
  assert_false(ok_i, "inflight full")
  state.release_inflight({ state_backend = "local", shared_dict = "ai_router", max_inflight = 1 })

  ngx.shared.ai_router = nil
end


-- ---- sse_usage ----
do
  local sse = require "kong.plugins.ai-router.sse_usage"
  local st = sse.new()
  sse.feed(st, 'data: {"usage":{"prompt_tokens":3,"completion_tokens":7}}\n\n')
  local pt, ct = sse.finish(st)
  assert_eq(pt, 3, "sse prompt")
  assert_eq(ct, 7, "sse completion")
end


-- ---- providers.parse_model ----
do
  local providers = require "kong.plugins.ai-router.providers"
  local p, m = providers.parse_model("openai/gpt-4o")
  assert_eq(p, "openai", "openai provider")
  assert_eq(m, "gpt-4o", "openai model")

  p, m = providers.parse_model("anthropic/claude-3")
  assert_eq(p, "anthropic", "anthropic")

  p, m = providers.parse_model("bedrock/us.anthropic.claude")
  assert_eq(p, "bedrock", "bedrock")

  p, m = providers.parse_model("gemini/gemini-2.0-flash")
  assert_eq(p, "gemini", "gemini")

  p, m = providers.parse_model("groq/llama3")
  assert_eq(p, "openai", "groq compat adapter")
end


-- ---- analytics / file-log serialize ----
do
  local analytics = require "kong.plugins.ai-router.analytics"
  local serialized = {}
  kong.log.set_serialize_value = function(key, value)
    serialized[key] = value
  end

  assert_false(analytics.enabled({}), "disabled without logging")
  assert_false(analytics.enabled({ logging = { log_statistics = false } }), "explicitly disabled")
  assert_true(analytics.enabled({ logging = { log_statistics = true } }), "enabled")

  ngx.ctx = {}
  serialized = {}
  local conf_off = { logging = { log_statistics = false } }
  analytics.start(conf_off)
  analytics.record_success(conf_off, {
    status = 200, model = "gpt-4o", prompt_tokens = 1, completion_tokens = 2,
  })
  assert_false(analytics.serialize(conf_off), "no serialize when off")
  assert_eq(serialized["ai.router.meta"], nil, "no meta when off")

  ngx.ctx = {}
  serialized = {}
  local conf_on = {
    logging = { log_statistics = true },
    __plugin_id = "pid-1",
  }
  analytics.start(conf_on)
  analytics.record_success(conf_on, {
    status = 200,
    provider = "openai",
    request_model = "auto",
    model = "gpt-4o",
    upstream_model = "gpt-4o-2024",
    deployment = "dep-1",
    attempts = 2,
    strategy = "simple-shuffle",
    endpoint = "chat",
    stream = false,
    latency = 150,
    prompt_tokens = 10,
    completion_tokens = 5,
    cost = 0.05,
    spend = 1.2,
    max_budget = 10,
  })
  assert_true(analytics.serialize(conf_on), "serialize ok")
  local meta = serialized["ai.router.meta"]
  local usage = serialized["ai.router.usage"]
  assert_true(type(meta) == "table", "meta table")
  assert_true(type(usage) == "table", "usage table")
  assert_eq(meta.plugin_id, "pid-1", "plugin_id")
  assert_eq(meta.provider_name, "openai", "provider")
  assert_eq(meta.request_model, "auto", "request_model")
  assert_eq(meta.response_model, "gpt-4o", "response_model")
  assert_eq(meta.upstream_model, "gpt-4o-2024", "upstream_model")
  assert_eq(meta.deployment, "dep-1", "deployment")
  assert_eq(meta.attempts, 2, "attempts")
  assert_eq(meta.llm_latency, 150, "llm_latency meta")
  assert_eq(meta.success, true, "success")
  assert_eq(usage.prompt_tokens, 10, "prompt_tokens")
  assert_eq(usage.completion_tokens, 5, "completion_tokens")
  assert_eq(usage.total_tokens, 15, "total_tokens")
  assert_eq(usage.llm_latency, 150, "llm_latency usage")
  assert_true(math.abs((usage.time_per_token or 0) - 30) < 1e-9, "time_per_token")
  assert_eq(usage.cost, 0.05, "cost")

  -- log phase re-serialize is idempotent
  serialized = {}
  assert_true(analytics.log(conf_on), "log phase")
  assert_eq(serialized["ai.router.usage"].total_tokens, 15, "log phase usage")

  ngx.ctx = {}
  serialized = {}
end


io.write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
  os.exit(1)
end
os.exit(0)
