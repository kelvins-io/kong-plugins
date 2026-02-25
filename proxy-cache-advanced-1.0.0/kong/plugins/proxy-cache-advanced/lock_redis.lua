---
--- Created by yq
--- DateTime: 2026/2/25 23:00
---

---
--- 防缓存击穿用 Redis 分布式锁，与缓存存储策略的 Redis 配置分离，使用独立连接配置。
---
local redis = require "resty.redis"


local type         = type
local setmetatable = setmetatable
local tostring     = tostring


local _M = {}


local REDIS_POOL_SIZE = 50
local REDIS_POOL_IDLE_TIMEOUT = 10000
local REDIS_CONNECT_TIMEOUT_MS = 60000


local function with_redis_client(opts, callback)
  local red = redis:new()
  local timeout_ms = (opts.timeout and opts.timeout > 0) and (opts.timeout * 1000) or REDIS_CONNECT_TIMEOUT_MS
  red:set_timeout(timeout_ms)

  local ok, err = red:connect(opts.host or "127.0.0.1", opts.port or 6379)
  if not ok then
    return nil, "lock_redis: failed to connect: " .. tostring(err)
  end

  if opts.ssl then
    local ssl_ok, ssl_err = red:ssl_handshake(nil, opts.server_name, opts.ssl_verify)
    if not ssl_ok then
      red:close()
      return nil, "lock_redis: SSL handshake failed: " .. tostring(ssl_err)
    end
  end

  if opts.password then
    if opts.username then
      local auth_ok, auth_err = red:auth(opts.username, opts.password)
      if not auth_ok then
        red:close()
        return nil, "lock_redis: auth failed: " .. tostring(auth_err)
      end
    else
      local auth_ok, auth_err = red:auth(opts.password)
      if not auth_ok then
        red:close()
        return nil, "lock_redis: auth failed: " .. tostring(auth_err)
      end
    end
  end

  if opts.database and opts.database ~= 0 then
    local select_ok, select_err = red:select(opts.database)
    if not select_ok then
      red:close()
      return nil, "lock_redis: select database failed: " .. tostring(select_err)
    end
  end

  local results = { callback(red) }
  red:set_keepalive(REDIS_POOL_IDLE_TIMEOUT, REDIS_POOL_SIZE)
  return table.unpack(results)
end


local function build_lock_key(opts, cache_key)
  local prefix = opts.key_prefix or "proxy-cache-advanced:lock:"
  return prefix .. cache_key
end


local RELEASE_LOCK_SCRIPT = [[
  if redis.call('get', KEYS[1]) == ARGV[1] then
    return redis.call('del', KEYS[1])
  else
    return 0
  end
]]


function _M.new(opts)
  if not opts or not opts.host then
    return nil, "lock_redis: opts and opts.host are required"
  end
  return setmetatable({ opts = opts }, { __index = _M })
end


--- 尝试获取分布式锁
-- @string cache_key 缓存键
-- @int[opt] ttl 锁 TTL 秒数
-- @return 成功返回 token，失败返回 nil
function _M:acquire_lock(cache_key, ttl)
  if type(cache_key) ~= "string" then
    return nil
  end
  local lock_key = build_lock_key(self.opts, cache_key)
  ttl = ttl or self.opts.cache_lock_ttl or 10
  if ttl <= 0 then
    ttl = 10
  end
  -- 生成唯一 token（不依赖 ngx.worker_pid，Kong 环境下可能为 nil）
  local pid = (ngx.worker_pid and ngx.worker_pid()) or (ngx.var and ngx.var.pid) or ""
  local token = tostring(pid) .. ":" .. tostring(ngx.now()) .. ":" .. tostring(ngx.var and ngx.var.connection or "") .. ":" .. tostring(math.random(1, 999999999))
  local ok, err = with_redis_client(self.opts, function(red)
    local res, set_err = red:set(lock_key, token, "EX", ttl, "NX")
    if not res then
      return nil, set_err
    end
    if res == ngx.null or not res then
      return nil
    end
    return token
  end)
  if ok then
    return ok
  end
  return nil
end


--- 释放分布式锁（仅当 value 等于 token 时删除）
-- @string cache_key 缓存键
-- @string token acquire_lock 返回的 token
-- @return 成功返回 true，否则 false
function _M:release_lock(cache_key, token)
  if type(cache_key) ~= "string" or type(token) ~= "string" then
    return false
  end
  local lock_key = build_lock_key(self.opts, cache_key)
  local ok, err = with_redis_client(self.opts, function(red)
    local res, script_err = red:eval(RELEASE_LOCK_SCRIPT, 1, lock_key, token)
    if not res or script_err then
      return false
    end
    return res == 1
  end)
  return ok == true
end


return _M
