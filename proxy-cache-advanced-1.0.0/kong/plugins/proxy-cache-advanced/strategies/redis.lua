---
--- Created by kelvins-io.
--- DateTime: 2026/1/10 16:05
---
local cjson = require "cjson.safe"
local redis = require "resty.redis"
local type         = type
local time         = ngx.time
local setmetatable = setmetatable
local tostring     = tostring
local ceil         = math.ceil
local concat       = table.concat


local _M = {}


-- Redis连接池配置
local REDIS_POOL_SIZE = 100
local REDIS_POOL_IDLE_TIMEOUT = 10000  -- 10秒
local REDIS_CONNECT_TIMEOUT = 60000     -- 1秒

-- 超过此大小（字节）的 JSON 将拆分为多个 Redis key 存储；可通过 opts.chunk_size 覆盖
local DEFAULT_CHUNK_SIZE = 524288  -- 512 KiB


--- 获取Redis连接并执行操作
-- @table self 策略实例
-- @function callback 回调函数，接收redis客户端作为参数
-- @return 回调函数的返回值
local function with_redis_client(self, callback)
  local red = redis:new()

  -- 设置超时时间
  red:set_timeout(self.opts.timeout * 1000 or REDIS_CONNECT_TIMEOUT)

  -- 连接到Redis服务器
  local ok, err = red:connect(self.opts.host or "127.0.0.1", self.opts.port or 6379)
  if not ok then
    return nil, "failed to connect to Redis: " .. tostring(err)
  end

  -- SSL连接处理
  if self.opts.ssl then
    local ssl_ok, ssl_err = red:ssl_handshake(nil, self.opts.server_name, self.opts.ssl_verify)
    if not ssl_ok then
      red:close()
      return nil, "failed to perform SSL handshake: " .. tostring(ssl_err)
    end
  end

  -- 认证处理
  if self.opts.password then
    if self.opts.username then
      -- ACL认证（Redis 6.0+）
      local auth_ok, auth_err = red:auth(self.opts.username, self.opts.password)
      if not auth_ok then
        red:close()
        return nil, "failed to authenticate with Redis: " .. tostring(auth_err)
      end
    else
      -- 传统密码认证
      local auth_ok, auth_err = red:auth(self.opts.password)
      if not auth_ok then
        red:close()
        return nil, "failed to authenticate with Redis: " .. tostring(auth_err)
      end
    end
  end

  -- 选择数据库
  if self.opts.database and self.opts.database ~= 0 then
    local select_ok, select_err = red:select(self.opts.database)
    if not select_ok then
      red:close()
      return nil, "failed to select Redis database: " .. tostring(select_err)
    end
  end

  -- 执行回调函数并捕获所有返回值
  local results = { callback(red) }

  -- 将连接放回连接池
  local pool_ok, pool_err = red:set_keepalive(REDIS_POOL_IDLE_TIMEOUT, REDIS_POOL_SIZE)
  if not pool_ok then
    red:close()
  end

  -- 返回所有结果（使用table.unpack以兼容Lua 5.2+，LuaJIT也支持）
  return table.unpack(results)
end


--- 构建完整的Redis键名
-- @table self 策略实例
-- @string key 缓存键
-- @return 完整的Redis键名
local function build_redis_key(self, key)
  local prefix = self.opts.key_prefix or "proxy-cache-advanced:"
  return prefix .. key
end


local function build_chunk_key(redis_key, index)
  return redis_key .. ":chunk:" .. index
end


local function get_chunk_size(self)
  local size = self.opts.chunk_size
  if size == nil then
    return DEFAULT_CHUNK_SIZE
  end

  if size <= 0 then
    return nil
  end

  return size
end


local function is_chunked_meta(val)
  if type(val) ~= "table" then
    return false
  end

  return val.__pca_chunked == true
    and type(val.chunks) == "number"
    and val.chunks > 0
end


--- 删除缓存条目（兼容单 key 与分片两种格式）
local function delete_entry(red, redis_key)
  local val, get_err = red:get(redis_key)
  if get_err then
    return nil, "failed to get from Redis: " .. tostring(get_err)
  end

  if val and val ~= ngx.null then
    local meta = cjson.decode(val)
    if is_chunked_meta(meta) then
      local keys = { redis_key }
      for i = 0, meta.chunks - 1 do
        keys[#keys + 1] = build_chunk_key(redis_key, i)
      end
      local del_ok, del_err = red:del(table.unpack(keys))
      if not del_ok then
        return nil, "failed to delete from Redis: " .. tostring(del_err)
      end
      return true
    end
  end

  local del_ok, del_err = red:del(redis_key)
  if not del_ok then
    return nil, "failed to delete from Redis: " .. tostring(del_err)
  end
  return true
end


--- 分片写入：先写各 chunk，最后写主 key 元数据，避免 fetch 读到不完整数据
local function store_chunked(red, redis_key, req_json, ttl, chunk_size)
  local total_len = #req_json
  local num_chunks = ceil(total_len / chunk_size)

  red:init_pipeline()
  for i = 0, num_chunks - 1 do
    local start = i * chunk_size + 1
    local chunk = req_json:sub(start, start + chunk_size - 1)
    red:setex(build_chunk_key(redis_key, i), ttl, chunk)
  end

  local meta_json = cjson.encode({
    __pca_chunked = true,
    chunks = num_chunks,
  })
  if not meta_json then
    return nil, "could not encode chunk metadata"
  end
  red:setex(redis_key, ttl, meta_json)

  local results, pipe_err = red:commit_pipeline()
  if not results then
    return nil, "failed to store chunks in Redis: " .. tostring(pipe_err)
  end

  for i = 1, #results do
    local res = results[i]
    if res == false or res == nil then
      return nil, "failed to store chunk in Redis at index " .. (i - 1)
    end
  end

  return true
end


--- 读取分片并拼接为完整 JSON
local function fetch_chunked(red, redis_key, meta)
  local chunk_keys = {}
  for i = 0, meta.chunks - 1 do
    chunk_keys[#chunk_keys + 1] = build_chunk_key(redis_key, i)
  end

  local chunks, get_err = red:mget(table.unpack(chunk_keys))
  if not chunks then
    return nil, "failed to get chunks from Redis: " .. tostring(get_err)
  end

  for i = 1, #chunks do
    if not chunks[i] or chunks[i] == ngx.null or chunks[i] == "" then
      delete_entry(red, redis_key)
      return nil, "request object not in cache"
    end
  end

  local req_json = concat(chunks)
  local req_obj = cjson.decode(req_json)
  if not req_obj then
    delete_entry(red, redis_key)
    return nil, "request object not in cache"
  end

  return req_obj
end


--- 创建新的Redis策略对象
-- @table opts Redis策略选项，包含host, port, password等配置
function _M.new(opts)
  if not opts then
    return nil, "redis options are required"
  end

  if not opts.host then
    return nil, "redis.host is required"
  end

  if not opts.port then
    return nil, "redis.port is required"
  end

  local self = {
    opts = opts,
  }

  return setmetatable(self, {
    __index = _M,
  })
end


--- 存储新的请求实体到Redis
-- @string key 请求键
-- @table req_obj 请求对象，包含需要缓存的所有内容
-- @int[opt] req_ttl 请求的TTL（秒）；如果为nil，使用策略实例化时指定的默认TTL
-- @return true和JSON字符串表示成功，nil和错误信息表示失败
function _M:store(key, req_obj, req_ttl)
  if type(key) ~= "string" then
    return nil, "key must be a string"
  end

  -- 编码请求表为JSON
  local req_json = cjson.encode(req_obj)
  if not req_json then
    return nil, "could not encode request object"
  end

  -- 构建完整的Redis键名
  local redis_key = build_redis_key(self, key)

  -- 计算TTL（秒）
  local ttl = req_ttl or self.opts.ttl
  if not ttl or ttl <= 0 then
    ttl = 3600  -- 默认1小时
  end

  local chunk_size = get_chunk_size(self)
  local use_chunks = chunk_size and #req_json > chunk_size

  -- 使用Redis连接执行存储操作
  return with_redis_client(self, function(red)
    -- 覆盖写入前先清理旧条目（单 key / 分片格式可能不同）
    local del_ok, del_err = delete_entry(red, redis_key)
    if not del_ok then
      return nil, del_err
    end

    if use_chunks then
      local store_ok, store_err = store_chunked(red, redis_key, req_json, ttl, chunk_size)
      if not store_ok then
        return nil, store_err
      end
      return true, req_json
    end

    -- 小对象仍使用单 key 存储，保持向后兼容
    local set_ok, set_err = red:setex(redis_key, ttl, req_json)
    if not set_ok then
      return nil, "failed to store in Redis: " .. tostring(set_err)
    end
    return true, req_json
  end)
end


--- 从Redis获取缓存的请求
-- @string key 请求键
-- @return 表示请求的表，或nil和错误信息
function _M:fetch(key)
  if type(key) ~= "string" then
    return nil, "key must be a string"
  end

  -- 构建完整的Redis键名
  local redis_key = build_redis_key(self, key)

  -- 使用Redis连接执行获取操作
  return with_redis_client(self, function(red)
    -- 从Redis获取值
    local req_json, get_err = red:get(redis_key)

    if not req_json or req_json == ngx.null then
      if not get_err then
        return nil, "request object not in cache"
      else
        return nil, "failed to get from Redis: " .. tostring(get_err)
      end
    end

    -- 分片格式：主 key 存元数据，各 chunk key 存 JSON 片段
    local meta = cjson.decode(req_json)
    if is_chunked_meta(meta) then
      return fetch_chunked(red, redis_key, meta)
    end

    -- 单 key 格式
    local req_obj = meta
    if not req_obj then
      delete_entry(red, redis_key)
      return nil, "request object not in cache"
    end

    return req_obj
  end)
end


--- 从请求缓存中清除一个条目
-- @string key 请求键
-- @return 成功返回true，失败返回nil和错误信息
function _M:purge(key)
  if type(key) ~= "string" then
    return nil, "key must be a string"
  end

  -- 构建完整的Redis键名
  local redis_key = build_redis_key(self, key)

  -- 使用Redis连接执行删除操作
  return with_redis_client(self, function(red)
    return delete_entry(red, redis_key)
  end)
end


--- 重置缓存请求的TTL
-- @string key 请求键
-- @int[opt] req_ttl 新的TTL（秒）
-- @int[opt] timestamp 时间戳；如果为nil，使用当前时间
-- @return 成功返回true和JSON字符串，失败返回nil和错误信息
function _M:touch(key, req_ttl, timestamp)
  if type(key) ~= "string" then
    return nil, "key must be a string"
  end

  -- 先获取现有的缓存对象
  local req_obj, err = self:fetch(key)
  if not req_obj then
    return nil, err or "request object not in cache"
  end

  -- 更新时间戳字段
  req_obj.timestamp = timestamp or time()

  -- 重新存储以重置TTL
  return self:store(key, req_obj, req_ttl)
end


--- 将所有条目标记为过期并从Redis中移除
-- @param free_mem Boolean，指示是否释放内存；如果为false，条目仅被标记为过期
-- @return 成功返回true，失败返回nil和错误信息
function _M:flush(free_mem)
  -- 构建键前缀模式
  local prefix = self.opts.key_prefix or "proxy-cache-advanced:"
  local pattern = prefix .. "*"

  -- 使用Redis连接执行清空操作
  return with_redis_client(self, function(red)
    -- 使用SCAN命令遍历所有匹配的键（避免阻塞）
    local cursor = "0"
    local keys_to_delete = {}

    repeat
      local scan_result, scan_err = red:scan(cursor, "MATCH", pattern, "COUNT", 100)
      if not scan_result then
        return nil, "failed to scan Redis keys: " .. tostring(scan_err)
      end

      cursor = scan_result[1]
      local keys = scan_result[2]

      -- 收集要删除的键
      for i = 1, #keys do
        keys_to_delete[#keys_to_delete + 1] = keys[i]
      end

      -- 如果收集的键太多，分批删除
      if #keys_to_delete >= 1000 then
        if #keys_to_delete > 0 then
          local del_ok, del_err = red:del(table.unpack(keys_to_delete))
          if not del_ok then
            return nil, "failed to delete keys from Redis: " .. tostring(del_err)
          end
          keys_to_delete = {}
        end
      end
    until cursor == "0"

    -- 删除剩余的键
    if #keys_to_delete > 0 then
      local del_ok, del_err = red:del(table.unpack(keys_to_delete))
      if not del_ok then
        return nil, "failed to delete keys from Redis: " .. tostring(del_err)
      end
    end

    return true
  end)
end


return _M
