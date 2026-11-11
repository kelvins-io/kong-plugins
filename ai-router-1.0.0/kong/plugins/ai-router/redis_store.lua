-- Redis backend for cross-node cooldown / busy / latency / usage / budget.
local redis = require "resty.redis"

local kong = kong
local ngx = ngx
local null = ngx.null
local tostring = tostring
local tonumber = tonumber
local type = type
local ipairs = ipairs


local _M = {}


local function present(str)
  return str and str ~= "" and str ~= null
end


local function ka_timeout(conf)
  local r = conf and conf.redis
  return (r and r.keepalive_timeout) or 60000
end


local function ka_pool(conf)
  local r = conf and conf.redis
  return (r and r.keepalive_pool_size) or 128
end


local function connect(conf)
  local rconf = conf.redis
  if not rconf or not rconf.host then
    return nil, "redis host not configured"
  end

  local red = redis:new()
  red:set_timeout(rconf.timeout or 2000)

  local ok, err = red:connect(rconf.host, rconf.port or 6379, {
    ssl = rconf.ssl,
    ssl_verify = rconf.ssl_verify,
    server_name = rconf.server_name,
  })
  if not ok then
    return nil, "redis connect: " .. tostring(err)
  end

  local times = red:get_reused_times()
  if times == 0 then
    if present(rconf.password) then
      local auth_ok, aerr
      if present(rconf.username) then
        auth_ok, aerr = red:auth(rconf.username, rconf.password)
      else
        auth_ok, aerr = red:auth(rconf.password)
      end
      if not auth_ok then
        red:close()
        return nil, "redis auth: " .. tostring(aerr)
      end
    end
    if (rconf.database or 0) ~= 0 then
      local sok, serr = red:select(rconf.database)
      if not sok then
        red:close()
        return nil, "redis select: " .. tostring(serr)
      end
    end
  end

  return red
end


local function keepalive(red, conf)
  if not red then
    return
  end
  local ok, err = red:set_keepalive(ka_timeout(conf), ka_pool(conf))
  if not ok then
    kong.log.debug("ai-router redis keepalive: ", err)
  end
end


local function prefix(conf)
  return (conf.redis and conf.redis.prefix) or "ai_router"
end


local function full_key(conf, key)
  return prefix(conf) .. ":" .. key
end


function _M.get(conf, key)
  local red, err = connect(conf)
  if not red then
    return nil, err
  end
  local v, gerr = red:get(full_key(conf, key))
  keepalive(red, conf)
  if gerr then
    return nil, gerr
  end
  if v == null then
    return nil
  end
  return v
end


--- Batch GET in one RTT. Returns array aligned with keys (nil if missing).
function _M.mget(conf, keys)
  if type(keys) ~= "table" or #keys == 0 then
    return {}
  end
  local red, err = connect(conf)
  if not red then
    return nil, err
  end

  local full = {}
  for i = 1, #keys do
    full[i] = full_key(conf, keys[i])
  end

  -- resty.redis mget(k1, k2, ...)
  local unpack_fn = table.unpack or unpack
  local values, gerr = red:mget(unpack_fn(full))
  keepalive(red, conf)
  if not values then
    return nil, gerr
  end

  local out = {}
  for i = 1, #keys do
    local v = values[i]
    if v == null or v == nil then
      out[i] = nil
    else
      out[i] = v
    end
  end
  return out
end


function _M.set(conf, key, value, ttl)
  local red, err = connect(conf)
  if not red then
    return nil, err
  end
  local full = full_key(conf, key)
  local ok, serr
  if ttl and ttl > 0 then
    ok, serr = red:setex(full, ttl, tostring(value))
  else
    ok, serr = red:set(full, tostring(value))
  end
  keepalive(red, conf)
  if not ok then
    return nil, serr
  end
  return true
end


function _M.del(conf, key)
  local red, err = connect(conf)
  if not red then
    return nil, err
  end
  red:del(full_key(conf, key))
  keepalive(red, conf)
  return true
end


--- Acquire a short-lived lock: SET key NX EX ttl.
--- Returns true (acquired), false (held by other), or nil, err (redis error).
function _M.try_lock(conf, key, ttl)
  local red, err = connect(conf)
  if not red then
    return nil, err
  end
  ttl = tonumber(ttl) or 1
  if ttl < 1 then
    ttl = 1
  end
  local full = full_key(conf, key)
  local res, serr = red:set(full, "1", "NX", "EX", ttl)
  keepalive(red, conf)
  if serr then
    return nil, serr
  end
  if res == null or res == nil then
    return false
  end
  return true
end


function _M.unlock(conf, key)
  return _M.del(conf, key)
end


--- INCRBY + optional EXPIRE in one pipeline (1 RTT).
--- Missing key is created by Redis INCRBY; `init` kept for API compat (unused).
function _M.incr(conf, key, delta, init, ttl) -- luacheck: ignore 212
  local red, err = connect(conf)
  if not red then
    return nil, err
  end
  local full = full_key(conf, key)
  delta = delta or 1

  red:init_pipeline()
  red:incrby(full, delta)
  if ttl and ttl > 0 then
    red:expire(full, ttl)
  end
  local results, perr = red:commit_pipeline()
  keepalive(red, conf)
  if not results then
    return nil, perr
  end
  local n = results[1]
  if not n then
    return nil, "incr failed"
  end
  return tonumber(n)
end


function _M.incrbyfloat(conf, key, delta, ttl)
  local red, err = connect(conf)
  if not red then
    return nil, err
  end
  local full = full_key(conf, key)
  red:init_pipeline()
  red:incrbyfloat(full, delta or 0)
  if ttl and ttl > 0 then
    red:expire(full, ttl)
  end
  local results, perr = red:commit_pipeline()
  keepalive(red, conf)
  if not results then
    return nil, perr
  end
  return tonumber(results[1])
end


-- Atomic budget charge: only increments when spend + cost <= max_budget (max<=0 = unlimited).
-- Returns: ok(boolean), new_or_current_spend(number), err
local CHARGE_SCRIPT = [[
local key = KEYS[1]
local cost = tonumber(ARGV[1])
local maxb = tonumber(ARGV[2])
if (not cost) or cost == 0 then
  local cur = tonumber(redis.call('GET', key) or '0') or 0
  return {0, cur}
end
if cost < 0 then
  local neu = tonumber(redis.call('INCRBYFLOAT', key, cost))
  return {0, neu}
end
local spend = tonumber(redis.call('GET', key) or '0') or 0
if maxb and maxb > 0 and (spend + cost) > maxb then
  return {1, spend}
end
local neu = tonumber(redis.call('INCRBYFLOAT', key, cost))
return {0, neu}
]]


function _M.try_charge(conf, key, cost, max_budget)
  local red, err = connect(conf)
  if not red then
    return nil, nil, err
  end
  local full = full_key(conf, key)
  local res, eerr = red:eval(CHARGE_SCRIPT, 1, full, tonumber(cost) or 0, tonumber(max_budget) or 0)
  keepalive(red, conf)
  if not res then
    return nil, nil, eerr
  end
  -- resty.redis returns array-like table for Redis array reply
  local code = tonumber(res[1])
  local spend = tonumber(res[2]) or 0
  if code == 1 then
    return false, spend, "budget_exceeded"
  end
  return true, spend
end


-- Atomic budget gate: deny when spend >= max_budget (same key as charge).
local ADMIT_SCRIPT = [[
local key = KEYS[1]
local maxb = tonumber(ARGV[1]) or 0
local spend = tonumber(redis.call('GET', key) or '0') or 0
if maxb > 0 and spend >= maxb then
  return {1, spend}
end
return {0, spend}
]]


--- Returns ok, spend, err — ok=false when already at/over max_budget.
function _M.try_budget_admit(conf, key, max_budget)
  local red, err = connect(conf)
  if not red then
    return nil, nil, err
  end
  local full = full_key(conf, key)
  local res, eerr = red:eval(ADMIT_SCRIPT, 1, full, tonumber(max_budget) or 0)
  keepalive(red, conf)
  if not res then
    return nil, nil, eerr
  end
  local code = tonumber(res[1])
  local spend = tonumber(res[2]) or 0
  if code == 1 then
    return false, spend, "budget_exceeded"
  end
  return true, spend
end


-- Atomic inflight acquire: INCR then DECR if over max (single Lua RTT).
local INFLIGHT_ACQUIRE_SCRIPT = [[
local key = KEYS[1]
local maxb = tonumber(ARGV[1]) or 0
local ttl = tonumber(ARGV[2]) or 600
local n = tonumber(redis.call('INCR', key))
if ttl > 0 then
  redis.call('EXPIRE', key, ttl)
end
if maxb > 0 and n > maxb then
  n = tonumber(redis.call('DECR', key))
  if n < 0 then
    redis.call('SET', key, '0')
    n = 0
  end
  return {0, n}
end
return {1, n}
]]


--- Returns ok, current_count, err
function _M.try_acquire_inflight(conf, key, max_inflight, ttl)
  local red, err = connect(conf)
  if not red then
    return nil, nil, err
  end
  local full = full_key(conf, key)
  local res, eerr = red:eval(
    INFLIGHT_ACQUIRE_SCRIPT, 1, full,
    tonumber(max_inflight) or 0,
    tonumber(ttl) or 600
  )
  keepalive(red, conf)
  if not res then
    return nil, nil, eerr
  end
  local code = tonumber(res[1])
  local n = tonumber(res[2]) or 0
  return code == 1, n
end


--- Run multiple write ops on one connection via pipeline.
--- ops: { {op="setex", key=, value=, ttl=}, {op="del", key=}, {op="incrby", key=, delta=, ttl=}, ... }
function _M.pipeline(conf, ops)
  if type(ops) ~= "table" or #ops == 0 then
    return true
  end
  local red, err = connect(conf)
  if not red then
    return nil, err
  end

  red:init_pipeline()
  for _, op in ipairs(ops) do
    local full = full_key(conf, op.key)
    if op.op == "set" or op.op == "setex" then
      if op.ttl and op.ttl > 0 then
        red:setex(full, op.ttl, tostring(op.value))
      else
        red:set(full, tostring(op.value))
      end
    elseif op.op == "del" then
      red:del(full)
    elseif op.op == "incrby" then
      red:incrby(full, op.delta or 1)
      if op.ttl and op.ttl > 0 then
        red:expire(full, op.ttl)
      end
    elseif op.op == "incrbyfloat" then
      red:incrbyfloat(full, op.delta or 0)
      if op.ttl and op.ttl > 0 then
        red:expire(full, op.ttl)
      end
    end
  end

  local results, perr = red:commit_pipeline()
  keepalive(red, conf)
  if not results then
    return nil, perr
  end
  return results
end


return _M
