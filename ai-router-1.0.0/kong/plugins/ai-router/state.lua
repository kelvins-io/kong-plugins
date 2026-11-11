-- State backend: local shared dict or Redis (cross-node).
-- Routing hot path: one MGET prefetch + optional L1 shdict cooldown cache.
local redis_store = require "kong.plugins.ai-router.redis_store"

local ngx = ngx
local kong = kong
local tostring = tostring
local tonumber = tonumber
local floor = math.floor
local now = ngx.now
local type = type


local _M = {}


local warned_fallback
local last_redis_err_at = {}
local REDIS_ERR_INTERVAL = 5 -- seconds; one err per path, then debug


local function use_redis(conf)
  return conf and conf.state_backend == "redis"
end


--- Rate-limit Redis dependency errors so routing hot path does not flood error_log.
local function log_redis_err(path, err)
  local t = now()
  local prev = last_redis_err_at[path]
  if prev and (t - prev) < REDIS_ERR_INTERVAL then
    kong.log.debug("ai-router redis ", path, ": ", err)
    return
  end
  last_redis_err_at[path] = t
  kong.log.err("ai-router redis ", path, ": ", err)
end


local function dict(name)
  local d = ngx.shared[name]
  if d then
    return d
  end
  d = ngx.shared.kong
  if d then
    if not warned_fallback then
      warned_fallback = true
      kong.log.err("ai-router shared dict '", tostring(name),
        "' missing; falling back to 'kong'. Add: lua_shared_dict ",
        tostring(name), " 10m;")
    end
    return d
  end
  return nil, "missing shared dict '" .. tostring(name) .. "'"
end


local function cache_ttl(conf)
  local t = conf and conf.state_cache_ttl
  if t == nil then
    return 1
  end
  return tonumber(t) or 0
end


function _M.deployment_id(dep)
  local p = dep.litellm_params or {}
  return table.concat({
    dep.model_name or "",
    p.model or "",
    p.api_base or "",
    tostring(p.order or 1),
  }, "|")
end


local function snap()
  local ctx = ngx.ctx
  if type(ctx) ~= "table" then
    return nil
  end
  return ctx.ai_router_snap
end


--- Prefetch cooldown/busy/latency/usage for all deployments in one Redis MGET.
--- Stored in ngx.ctx.ai_router_snap for the current pick cycle.
function _M.prefetch(conf, deployments)
  if not use_redis(conf) or type(deployments) ~= "table" or #deployments == 0 then
    ngx.ctx.ai_router_snap = nil
    return nil
  end

  local minute = floor(now() / 60)
  local keys = {}
  local index = {} -- id -> {cd=, busy=, lat=, rpm=, tpm=} offsets in keys

  for i = 1, #deployments do
    local id = _M.deployment_id(deployments[i])
    if not index[id] then
      local base = #keys
      keys[base + 1] = "cd:" .. id
      keys[base + 2] = "busy:" .. id
      keys[base + 3] = "lat:" .. id
      keys[base + 4] = "rpm:" .. id .. ":" .. minute
      keys[base + 5] = "tpm:" .. id .. ":" .. minute
      index[id] = base
    end
  end

  local values, err = redis_store.mget(conf, keys)
  if not values then
    log_redis_err("prefetch", err)
    ngx.ctx.ai_router_snap = nil
    return nil
  end

  local s = {}
  for id, base in pairs(index) do
    s[id] = {
      cd = values[base + 1],
      busy = tonumber(values[base + 2]) or 0,
      lat = tonumber(values[base + 3]),
      rpm = tonumber(values[base + 4]) or 0,
      tpm = tonumber(values[base + 5]) or 0,
    }
  end
  ngx.ctx.ai_router_snap = s
  return s
end


function _M.clear_prefetch()
  ngx.ctx.ai_router_snap = nil
end


local function local_cd_get(conf, id)
  local ttl = cache_ttl(conf)
  if ttl <= 0 then
    return nil
  end
  local d = dict(conf.shared_dict)
  if not d then
    return nil
  end
  return tonumber(d:get("lcd:" .. id))
end


local function local_cd_set(conf, id, until_ts, ttl)
  local cache_t = cache_ttl(conf)
  if cache_t <= 0 then
    return
  end
  local d = dict(conf.shared_dict)
  if not d then
    return
  end
  local expire = ttl or cache_t
  if until_ts and until_ts > now() then
    expire = math.max(expire, math.ceil(until_ts - now()))
  end
  d:set("lcd:" .. id, until_ts, expire)
end


local function local_cd_clear(conf, id)
  local d = dict(conf.shared_dict)
  if d then
    d:delete("lcd:" .. id)
  end
end


function _M.is_cooled(conf, dep)
  local id = _M.deployment_id(dep)

  local lcd = local_cd_get(conf, id)
  if lcd and lcd > now() then
    return true
  end

  local s = snap()
  if s and s[id] then
    local v = tonumber(s[id].cd)
    return v and v > now()
  end

  if use_redis(conf) then
    local v, err = redis_store.get(conf, "cd:" .. id)
    if err then
      log_redis_err("is_cooled", err)
      return false
    end
    local until_ts = tonumber(v)
    if until_ts and until_ts > now() then
      local_cd_set(conf, id, until_ts, conf.cooldown_time or 5)
      return true
    end
    return false
  end

  local d, err = dict(conf.shared_dict)
  if not d then
    kong.log.err("ai-router is_cooled dict: ", err)
    return false
  end
  local until_ts = d:get("cd:" .. id)
  if not until_ts then
    return false
  end
  return tonumber(until_ts) > now()
end


function _M.mark_fail(conf, dep)
  local id = _M.deployment_id(dep)
  local ttl = conf.cooldown_time or 5

  if use_redis(conf) then
    local n, err = redis_store.incr(conf, "fail:" .. id, 1, 0, ttl)
    if not n then
      log_redis_err("mark_fail", err)
      return
    end
    if n >= (conf.allowed_fails or 3) then
      local until_ts = now() + ttl
      redis_store.pipeline(conf, {
        { op = "setex", key = "cd:" .. id, value = until_ts, ttl = ttl },
        { op = "del", key = "fail:" .. id },
      })
      local_cd_set(conf, id, until_ts, ttl)
      local s = snap()
      if s and s[id] then
        s[id].cd = until_ts
      end
    end
    return
  end

  local d, err = dict(conf.shared_dict)
  if not d then
    kong.log.err("ai-router mark_fail dict: ", err)
    return
  end
  local n, serr = d:incr("fail:" .. id, 1, 0, ttl)
  if not n then
    kong.log.err("ai-router mark_fail incr: ", serr)
    return
  end
  if n >= (conf.allowed_fails or 3) then
    local until_ts = now() + ttl
    d:set("cd:" .. id, until_ts, ttl)
    d:delete("fail:" .. id)
  end
end


--- opts.rpm_reserved=true: rpm already incremented by usage_try_reserve; only add tpm/latency.
function _M.mark_success(conf, dep, latency_ms, prompt_tokens, completion_tokens, opts)
  opts = opts or {}
  local rpm_reserved = opts.rpm_reserved == true
  local id = _M.deployment_id(dep)
  local minute = floor(now() / 60)
  local tokens = (tonumber(prompt_tokens) or 0) + (tonumber(completion_tokens) or 0)

  -- Serialize rpm/tpm updates against usage-based locked reads/reserves.
  local got_lock = _M.acquire_usage_lock(conf, id)
  if not got_lock then
    kong.log.debug("ai-router usage lock timeout on mark_success; updating unlocked dep=", id)
  end

  local function release()
    if got_lock then
      _M.release_usage_lock(conf, id)
      got_lock = false
    end
  end

  if use_redis(conf) then
    local ops = {
      { op = "del", key = "fail:" .. id },
    }
    if not rpm_reserved then
      ops[#ops + 1] = {
        op = "incrby", key = "rpm:" .. id .. ":" .. minute, delta = 1, ttl = 120,
      }
    end
    if tokens > 0 then
      ops[#ops + 1] = {
        op = "incrby", key = "tpm:" .. id .. ":" .. minute, delta = tokens, ttl = 120,
      }
    end

    local ema
    if latency_ms and latency_ms > 0 then
      local prev
      local s = snap()
      if s and s[id] and s[id].lat then
        prev = s[id].lat
      else
        prev = tonumber(select(1, redis_store.get(conf, "lat:" .. id))) or latency_ms
      end
      ema = prev * 0.7 + latency_ms * 0.3
      ops[#ops + 1] = { op = "setex", key = "lat:" .. id, value = ema, ttl = 3600 }
    end

    if #ops > 0 then
      redis_store.pipeline(conf, ops)
    end
    local_cd_clear(conf, id)

    local s = snap()
    if s and s[id] then
      s[id].cd = nil
      if ema then
        s[id].lat = ema
      end
      if not rpm_reserved then
        s[id].rpm = (s[id].rpm or 0) + 1
      end
      s[id].tpm = (s[id].tpm or 0) + tokens
    end
    release()
    return
  end

  local d = dict(conf.shared_dict)
  if not d then
    release()
    return
  end
  d:delete("fail:" .. id)
  if latency_ms and latency_ms > 0 then
    local lk = "lat:" .. id
    local prev = tonumber(d:get(lk)) or latency_ms
    d:set(lk, prev * 0.7 + latency_ms * 0.3, 3600)
  end
  if not rpm_reserved then
    d:incr("rpm:" .. id .. ":" .. minute, 1, 0, 120)
  end
  if tokens > 0 then
    d:incr("tpm:" .. id .. ":" .. minute, tokens, 0, 120)
  end
  release()
end


function _M.get_latency(conf, dep)
  local id = _M.deployment_id(dep)
  local s = snap()
  if s and s[id] then
    return s[id].lat
  end
  if use_redis(conf) then
    return tonumber(select(1, redis_store.get(conf, "lat:" .. id)))
  end
  local d = dict(conf.shared_dict)
  if not d then
    return nil
  end
  return tonumber(d:get("lat:" .. id))
end


function _M.get_busy(conf, dep)
  local id = _M.deployment_id(dep)
  local s = snap()
  if s and s[id] then
    return s[id].busy or 0
  end
  if use_redis(conf) then
    return tonumber(select(1, redis_store.get(conf, "busy:" .. id))) or 0
  end
  local d = dict(conf.shared_dict)
  if not d then
    return 0
  end
  return tonumber(d:get("busy:" .. id)) or 0
end


function _M.incr_busy(conf, dep, delta)
  local id = _M.deployment_id(dep)
  if use_redis(conf) then
    local n = redis_store.incr(conf, "busy:" .. id, delta, 0, 600)
    if n and n < 0 then
      redis_store.set(conf, "busy:" .. id, 0, 600)
      n = 0
    end
    local s = snap()
    if s and s[id] then
      s[id].busy = n or ((s[id].busy or 0) + delta)
      if s[id].busy < 0 then
        s[id].busy = 0
      end
    end
    return
  end
  local d = dict(conf.shared_dict)
  if not d then
    return
  end
  local n = d:incr("busy:" .. id, delta, 0, 600)
  if n and n < 0 then
    d:set("busy:" .. id, 0, 600)
  end
end


--- Per-deployment lock for rpm/tpm read+write (usage-based-routing).
--- Local: shdict add NX; Redis: SET NX EX. Mirrors spend_lock pattern.
local USAGE_LOCK_TTL = 1
local USAGE_LOCK_TRIES = 50
local USAGE_LOCK_SLEEP = 0.001


function _M.acquire_usage_lock(conf, id)
  if not id or id == "" then
    return false
  end
  local lock_key = "usage_lock:" .. id

  if use_redis(conf) then
    for _ = 1, USAGE_LOCK_TRIES do
      local ok, err = redis_store.try_lock(conf, lock_key, USAGE_LOCK_TTL)
      if ok == true then
        return true
      end
      if ok == nil then
        log_redis_err("usage_lock", err)
        return false
      end
      ngx.sleep(USAGE_LOCK_SLEEP)
    end
    return false
  end

  local d = dict(conf.shared_dict)
  if not d then
    return false
  end
  for _ = 1, USAGE_LOCK_TRIES do
    local got = d:add(lock_key, true, USAGE_LOCK_TTL)
    if got then
      return true
    end
    ngx.sleep(USAGE_LOCK_SLEEP)
  end
  return false
end


function _M.release_usage_lock(conf, id)
  if not id or id == "" then
    return
  end
  local lock_key = "usage_lock:" .. id
  if use_redis(conf) then
    redis_store.unlock(conf, lock_key)
    return
  end
  local d = dict(conf.shared_dict)
  if d then
    d:delete(lock_key)
  end
end


local function read_usage_fresh(conf, id)
  local minute = floor(now() / 60)
  if use_redis(conf) then
    local values = redis_store.mget(conf, {
      "rpm:" .. id .. ":" .. minute,
      "tpm:" .. id .. ":" .. minute,
    })
    if values then
      return tonumber(values[1]) or 0, tonumber(values[2]) or 0
    end
    return 0, 0
  end
  local d = dict(conf.shared_dict)
  if not d then
    return 0, 0
  end
  local rpm = tonumber(d:get("rpm:" .. id .. ":" .. minute)) or 0
  local tpm = tonumber(d:get("tpm:" .. id .. ":" .. minute)) or 0
  return rpm, tpm
end


--- opts.locked=true: acquire usage lock, bypass snap, fresh read (for usage-based).
--- opts.fresh=true: bypass snap without locking.
--- Lock timeout → still fresh-read unlocked (best effort) so routing can proceed.
function _M.get_usage(conf, dep, opts)
  opts = opts or {}
  local id = _M.deployment_id(dep)
  local use_lock = opts.locked == true
  local fresh = use_lock or opts.fresh == true
  local got_lock = false

  if use_lock then
    got_lock = _M.acquire_usage_lock(conf, id)
    if not got_lock then
      kong.log.debug("ai-router usage lock timeout on get_usage; reading unlocked dep=", id)
    end
  elseif not fresh then
    local s = snap()
    if s and s[id] then
      return s[id].rpm or 0, s[id].tpm or 0
    end
  end

  local rpm, tpm = read_usage_fresh(conf, id)

  local s = snap()
  if s and s[id] then
    s[id].rpm = rpm
    s[id].tpm = tpm
  end

  if got_lock then
    _M.release_usage_lock(conf, id)
  end
  return rpm, tpm
end


local function incr_usage_counter(conf, id, kind, delta, minute)
  minute = minute or floor(now() / 60)
  local key = kind .. ":" .. id .. ":" .. minute
  if use_redis(conf) then
    local n = redis_store.incr(conf, key, delta, 0, 120)
    if n and n < 0 then
      redis_store.set(conf, key, 0, 120)
      n = 0
    end
    local s = snap()
    if s and s[id] and kind == "rpm" then
      s[id].rpm = n or 0
    elseif s and s[id] and kind == "tpm" then
      s[id].tpm = n or 0
    end
    return n or 0
  end
  local d = dict(conf.shared_dict)
  if not d then
    return 0
  end
  local n = d:incr(key, delta, 0, 120)
  if n and n < 0 then
    d:set(key, 0, 120)
    n = 0
  end
  return n or 0
end


--- Atomically check rpm/tpm ceilings and pre-increment rpm (request slot).
--- Returns ok, reserved (reserved=true → release on failure; skip rpm incr in mark_success).
function _M.usage_try_reserve(conf, dep)
  local p = (dep and dep.litellm_params) or {}
  local has_rpm = p.rpm and tonumber(p.rpm) and tonumber(p.rpm) > 0
  local has_tpm = p.tpm and tonumber(p.tpm) and tonumber(p.tpm) > 0
  if not has_rpm and not has_tpm then
    return true, false
  end

  local id = _M.deployment_id(dep)
  local got_lock = _M.acquire_usage_lock(conf, id)
  if not got_lock then
    kong.log.debug("ai-router usage lock timeout on reserve; admitting unlocked dep=", id)
    return true, false
  end

  local rpm, tpm = read_usage_fresh(conf, id)
  local rpm_lim = tonumber(p.rpm)
  local tpm_lim = tonumber(p.tpm)
  if has_rpm and rpm >= rpm_lim then
    _M.release_usage_lock(conf, id)
    return false, false
  end
  if has_tpm and tpm >= tpm_lim then
    _M.release_usage_lock(conf, id)
    return false, false
  end

  local reserved = false
  if has_rpm then
    incr_usage_counter(conf, id, "rpm", 1)
    reserved = true
    local s = snap()
    if s and s[id] then
      s[id].rpm = (s[id].rpm or rpm) + 1
    end
  end

  _M.release_usage_lock(conf, id)
  return true, reserved
end


function _M.usage_release_reserve(conf, dep)
  if not dep then
    return
  end
  local id = _M.deployment_id(dep)
  local got_lock = _M.acquire_usage_lock(conf, id)
  if not got_lock then
    kong.log.debug("ai-router usage lock timeout on release; decrementing unlocked dep=", id)
  end
  incr_usage_counter(conf, id, "rpm", -1)
  if got_lock then
    _M.release_usage_lock(conf, id)
  end
end


--- Budget helpers (spend tracked in USD or token units depending on config)
function _M.get_spend(conf, key_id)
  if use_redis(conf) then
    return tonumber(select(1, redis_store.get(conf, "spend:" .. key_id))) or 0
  end
  local d = dict(conf.shared_dict)
  if not d then
    return 0
  end
  return tonumber(d:get("spend:" .. key_id)) or 0
end


function _M.add_spend(conf, key_id, amount)
  if not amount or amount == 0 then
    return _M.get_spend(conf, key_id)
  end
  if use_redis(conf) then
    return redis_store.incrbyfloat(conf, "spend:" .. key_id, amount, 0) or 0
  end
  local d = dict(conf.shared_dict)
  if not d then
    return 0
  end
  -- shared dict has no incrbyfloat; emulate
  local cur = tonumber(d:get("spend:" .. key_id)) or 0
  local neu = cur + amount
  d:set("spend:" .. key_id, neu)
  return neu
end


--- Pure helper (also used by unit tests): decide if charge is allowed.
function _M.budget_charge_decision(spend, cost, max_budget)
  spend = tonumber(spend) or 0
  cost = tonumber(cost) or 0
  max_budget = tonumber(max_budget) or 0
  if cost == 0 then
    return true, spend
  end
  if cost < 0 then
    return true, spend + cost
  end
  if max_budget > 0 and (spend + cost) > max_budget then
    return false, spend
  end
  return true, spend + cost
end


--- Atomic pre-flight budget gate (same key / lock as charge).
--- Returns ok, spend, err — ok=false when spend >= max_budget.
function _M.budget_admit(conf, key_id, max_budget)
  max_budget = tonumber(max_budget) or 0
  if max_budget <= 0 then
    return true, _M.get_spend(conf, key_id)
  end

  if use_redis(conf) then
    local ok, spend, err = redis_store.try_budget_admit(conf, "spend:" .. key_id, max_budget)
    if ok == nil then
      log_redis_err("budget_admit", err)
      return false, _M.get_spend(conf, key_id), err or "redis_error"
    end
    return ok, spend, err
  end

  local d = dict(conf.shared_dict)
  if not d then
    return false, 0, "missing shared dict"
  end

  local lock_key = "spend_lock:" .. key_id
  local spend_key = "spend:" .. key_id
  for _ = 1, 25 do
    local got = d:add(lock_key, true, 1)
    if got then
      local cur = tonumber(d:get(spend_key)) or 0
      local ok = cur < max_budget
      d:delete(lock_key)
      if not ok then
        return false, cur, "budget_exceeded"
      end
      return true, cur
    end
    ngx.sleep(0.001)
  end

  local cur = tonumber(d:get(spend_key)) or 0
  return false, cur, "budget_lock_timeout"
end


--- Atomic charge with max_budget guard.
--- Returns ok, new_or_current_spend, err
function _M.try_add_spend(conf, key_id, amount, max_budget)
  amount = tonumber(amount) or 0
  max_budget = tonumber(max_budget) or 0

  if use_redis(conf) then
    local ok, spend, err = redis_store.try_charge(conf, "spend:" .. key_id, amount, max_budget)
    if ok == nil then
      log_redis_err("try_add_spend", err)
      -- fail closed on redis error when budget is enforced
      if max_budget > 0 then
        return false, _M.get_spend(conf, key_id), err or "redis_error"
      end
      return true, _M.add_spend(conf, key_id, amount)
    end
    return ok, spend, err
  end

  local d = dict(conf.shared_dict)
  if not d then
    return false, 0, "missing shared dict"
  end

  local lock_key = "spend_lock:" .. key_id
  local spend_key = "spend:" .. key_id
  for _ = 1, 25 do
    local got = d:add(lock_key, true, 1)
    if got then
      local cur = tonumber(d:get(spend_key)) or 0
      local ok, neu = _M.budget_charge_decision(cur, amount, max_budget)
      if ok then
        d:set(spend_key, neu)
      end
      d:delete(lock_key)
      if not ok then
        return false, cur, "budget_exceeded"
      end
      return true, neu
    end
    ngx.sleep(0.001)
  end

  -- lock timeout: fail closed when budget enforced
  local cur = tonumber(d:get(spend_key)) or 0
  if max_budget > 0 then
    return false, cur, "budget_lock_timeout"
  end
  local neu = cur + amount
  d:set(spend_key, neu)
  return true, neu
end


--- Global in-flight gate (protects worker connection slots).
function _M.get_inflight(conf)
  if use_redis(conf) then
    return tonumber(select(1, redis_store.get(conf, "inflight:global"))) or 0
  end
  local d = dict(conf.shared_dict)
  if not d then
    return 0
  end
  return tonumber(d:get("inflight:global")) or 0
end


function _M.incr_inflight(conf, delta)
  delta = delta or 1
  if use_redis(conf) then
    local n = redis_store.incr(conf, "inflight:global", delta, 0, 600)
    if n and n < 0 then
      redis_store.set(conf, "inflight:global", 0, 600)
      return 0
    end
    return n or 0
  end
  local d = dict(conf.shared_dict)
  if not d then
    return 0
  end
  local n = d:incr("inflight:global", delta, 0, 600)
  if n and n < 0 then
    d:set("inflight:global", 0, 600)
    return 0
  end
  return n or 0
end


--- Try acquire one inflight slot. Returns ok, current_count
--- Redis: single Lua INCR+cap; local: shdict lock then check-and-incr.
function _M.try_acquire_inflight(conf)
  local max = tonumber(conf.max_inflight) or 0
  if max <= 0 then
    return true, 0
  end

  if use_redis(conf) then
    local ok, n, err = redis_store.try_acquire_inflight(conf, "inflight:global", max, 600)
    if ok == nil then
      log_redis_err("inflight_acquire", err)
      return false, _M.get_inflight(conf)
    end
    return ok, n
  end

  local d = dict(conf.shared_dict)
  if not d then
    return false, 0
  end

  local lock_key = "inflight_lock:global"
  for _ = 1, 25 do
    local got = d:add(lock_key, true, 1)
    if got then
      local cur = tonumber(d:get("inflight:global")) or 0
      if cur >= max then
        d:delete(lock_key)
        return false, cur
      end
      local n = d:incr("inflight:global", 1, 0, 600)
      d:delete(lock_key)
      return true, n or (cur + 1)
    end
    ngx.sleep(0.001)
  end

  -- lock timeout: fall back to atomic incr+compensate
  local n = _M.incr_inflight(conf, 1)
  if n > max then
    _M.incr_inflight(conf, -1)
    return false, n - 1
  end
  return true, n
end


function _M.release_inflight(conf)
  local max = tonumber(conf.max_inflight) or 0
  if max <= 0 then
    return
  end
  _M.incr_inflight(conf, -1)
end


return _M
