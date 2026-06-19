---
--- 防缓存击穿用 resty.lock（基于 ngx.shared.DICT），与 memory/disk 存储配置分离。
---
local resty_lock = require "resty.lock"


local type         = type
local setmetatable = setmetatable


local _M = {}


local function build_lock_key(opts, cache_key)
  local prefix = opts.key_prefix or "proxy-cache-advanced:lock:"
  return prefix .. cache_key
end


function _M.new(opts)
  if not opts or not opts.dict_name then
    return nil, "lock_shm: opts.dict_name is required"
  end

  if not ngx.shared[opts.dict_name] then
    return nil, "lock_shm: missing shared dict '" .. opts.dict_name .. "'"
  end

  return setmetatable({ opts = opts }, { __index = _M })
end


--- 非阻塞尝试获取锁（同一 worker 内跨协程互斥；memory/disk 为节点本地策略）
-- @string cache_key 缓存键
-- @int[opt] ttl 锁 exptime 秒数
-- @return 成功返回 resty.lock 对象（作为 token），失败返回 nil
function _M:acquire_lock(cache_key, ttl)
  if type(cache_key) ~= "string" then
    return nil
  end

  ttl = ttl or self.opts.cache_lock_ttl or 10
  if ttl <= 0 then
    ttl = 10
  end

  local lock, err = resty_lock:new(self.opts.dict_name, {
    exptime = ttl,
    timeout = 0,
  })
  if not lock then
    return nil, err
  end

  local lock_key = build_lock_key(self.opts, cache_key)
  local elapsed, lock_err = lock:lock(lock_key)
  if not elapsed then
    return nil, lock_err
  end

  return lock
end


--- 释放 acquire_lock 返回的锁对象
-- @string _cache_key 缓存键（与 lock_redis API 对齐，此处未使用）
-- @table lock_obj acquire_lock 返回的 resty.lock 对象
-- @return 成功返回 true，否则 false
function _M:release_lock(_cache_key, lock_obj)
  if type(lock_obj) ~= "table" or type(lock_obj.unlock) ~= "function" then
    return false
  end

  local ok = lock_obj:unlock()
  return ok == 1 or ok == true
end


return _M
