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


io.write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
  os.exit(1)
end
os.exit(0)
