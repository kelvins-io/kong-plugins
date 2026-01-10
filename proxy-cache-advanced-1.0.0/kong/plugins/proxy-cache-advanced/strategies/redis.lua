---
--- Created by kelvins-io.
--- DateTime: 2026/1/10 16:04
---
local cjson = require "cjson.safe"
local redis = require "resty.redis"

local kong = kong
local type = type
local setmetatable = setmetatable
local fmt = string.format
local null = ngx.null
local unpack = unpack

local _M = {}

local function is_present(str)
  return str and str ~= "" and str ~= null
end

local function get_redis_connection(opts)
  local red = redis:new()
  red:set_timeout(opts.timeout or 2000)

  local sock_opts = {}
  sock_opts.ssl = opts.ssl or false
  sock_opts.ssl_verify = opts.ssl_verify or false
  sock_opts.server_name = opts.server_name

  -- use a special pool name only if database is set to non-zero
  -- otherwise use the default pool name host:port
  if opts.database and opts.database ~= 0 then
    sock_opts.pool = fmt("%s:%d;%d", opts.host, opts.port, opts.database)
  end

  local ok, err = red:connect(opts.host, opts.port, sock_opts)
  if not ok then
    kong.log.err("failed to connect to Redis: ", err)
    return nil, err
  end

  local times, err = red:get_reused_times()
  if err then
    kong.log.err("failed to get connect reused times: ", err)
    return nil, err
  end

  if times == 0 then
    if is_present(opts.password) then
      local ok, err
      if is_present(opts.username) then
        ok, err = kong.vault.try(function(cfg)
          return red:auth(cfg.username, cfg.password)
        end, opts)
      else
        ok, err = kong.vault.try(function(cfg)
          return red:auth(cfg.password)
        end, opts)
      end
      if not ok then
        kong.log.err("failed to auth Redis: ", err)
        return nil, err
      end
    end

    if opts.database and opts.database ~= 0 then
      -- Only call select first time, since we know the connection is shared
      -- between instances that use the same redis database
      local ok, err = red:select(opts.database)
      if not ok then
        kong.log.err("failed to change Redis database: ", err)
        return nil, err
      end
    end
  end

  return red
end

local function get_key_prefix(opts)
  return opts.key_prefix or "proxy-cache-advanced:"
end

local function get_full_key(opts, key)
  return get_key_prefix(opts) .. key
end

--- Create new Redis strategy object
-- @table opts Strategy options: contains Redis connection parameters
function _M.new(opts)
  local self = {
    opts = opts,
  }

  return setmetatable(self, {
    __index = _M,
  })
end

--- Store a new request entity in Redis
-- @string key The request key
-- @table req_obj The request object, represented as a table containing
--   everything that needs to be cached
-- @int[opt] ttl The TTL for the request; if nil, use default TTL from config
function _M:store(key, req_obj, req_ttl)
  local ttl = req_ttl or self.opts.cache_ttl or 300

  if type(key) ~= "string" then
    return nil, "key must be a string"
  end

  -- encode request table representation as JSON
  local req_json = cjson.encode(req_obj)
  if not req_json then
    return nil, "could not encode request object"
  end

  local red, err = get_redis_connection(self.opts)
  if not red then
    return nil, err or "failed to connect to Redis"
  end

  local full_key = get_full_key(self.opts, key)
  local ok, err = red:setex(full_key, ttl, req_json)
  if not ok then
    local keepalive_ok, keepalive_err = red:set_keepalive(10000, 100)
    if not keepalive_ok then
      kong.log.err("failed to set Redis keepalive: ", keepalive_err)
    end
    return nil, err or "failed to store in Redis"
  end

  local keepalive_ok, keepalive_err = red:set_keepalive(10000, 100)
  if not keepalive_ok then
    kong.log.err("failed to set Redis keepalive: ", keepalive_err)
  end

  return ok and req_json or nil, err
end

--- Fetch a cached request
-- @string key The request key
-- @return Table representing the request
function _M:fetch(key)
  if type(key) ~= "string" then
    return nil, "key must be a string"
  end

  local red, err = get_redis_connection(self.opts)
  if not red then
    return nil, err or "failed to connect to Redis"
  end

  local full_key = get_full_key(self.opts, key)
  local req_json, err = red:get(full_key)
  if err then
    local keepalive_ok, keepalive_err = red:set_keepalive(10000, 100)
    if not keepalive_ok then
      kong.log.err("failed to set Redis keepalive: ", keepalive_err)
    end
    return nil, err
  end

  local keepalive_ok, keepalive_err = red:set_keepalive(10000, 100)
  if not keepalive_ok then
    kong.log.err("failed to set Redis keepalive: ", keepalive_err)
  end

  if not req_json or req_json == null then
    return nil, "request object not in cache"
  end

  -- decode object from JSON to table
  local req_obj = cjson.decode(req_json)
  if not req_obj then
    return nil, "could not decode request object"
  end

  return req_obj
end

--- Purge an entry from the request cache
-- @string key The cache key to purge
-- @return true on success, nil plus error message otherwise
function _M:purge(key)
  if type(key) ~= "string" then
    return nil, "key must be a string"
  end

  local red, err = get_redis_connection(self.opts)
  if not red then
    return nil, err or "failed to connect to Redis"
  end

  local full_key = get_full_key(self.opts, key)
  local ok, err = red:del(full_key)
  if err then
    local keepalive_ok, keepalive_err = red:set_keepalive(10000, 100)
    if not keepalive_ok then
      kong.log.err("failed to set Redis keepalive: ", keepalive_err)
    end
    return nil, err
  end

  local keepalive_ok, keepalive_err = red:set_keepalive(10000, 100)
  if not keepalive_ok then
    kong.log.err("failed to set Redis keepalive: ", keepalive_err)
  end

  return true
end

--- Reset TTL for a cached request
-- @string key The cache key
-- @int req_ttl The new TTL
-- @int[opt] timestamp The timestamp to update
function _M:touch(key, req_ttl, timestamp)
  if type(key) ~= "string" then
    return nil, "key must be a string"
  end

  local red, err = get_redis_connection(self.opts)
  if not red then
    return nil, err or "failed to connect to Redis"
  end

  local full_key = get_full_key(self.opts, key)
  -- check if entry actually exists
  local exists, err = red:exists(full_key)
  if err then
    local keepalive_ok, keepalive_err = red:set_keepalive(10000, 100)
    if not keepalive_ok then
      kong.log.err("failed to set Redis keepalive: ", keepalive_err)
    end
    return nil, err
  end

  if exists == 0 then
    local keepalive_ok, keepalive_err = red:set_keepalive(10000, 100)
    if not keepalive_ok then
      kong.log.err("failed to set Redis keepalive: ", keepalive_err)
    end
    return nil, "request object not in cache"
  end

  -- get the current value
  local req_json, err = red:get(full_key)
  if err then
    local keepalive_ok, keepalive_err = red:set_keepalive(10000, 100)
    if not keepalive_ok then
      kong.log.err("failed to set Redis keepalive: ", keepalive_err)
    end
    return nil, err
  end

  if not req_json or req_json == null then
    local keepalive_ok, keepalive_err = red:set_keepalive(10000, 100)
    if not keepalive_ok then
      kong.log.err("failed to set Redis keepalive: ", keepalive_err)
    end
    return nil, "request object not in cache"
  end

  -- decode object from JSON to table
  local req_obj = cjson.decode(req_json)
  if not req_obj then
    local keepalive_ok, keepalive_err = red:set_keepalive(10000, 100)
    if not keepalive_ok then
      kong.log.err("failed to set Redis keepalive: ", keepalive_err)
    end
    return nil, "could not decode request object"
  end

  -- refresh timestamp field
  req_obj.timestamp = timestamp or ngx.time()

  -- store it again to reset the TTL
  local keepalive_ok, keepalive_err = red:set_keepalive(10000, 100)
  if not keepalive_ok then
    kong.log.err("failed to set Redis keepalive: ", keepalive_err)
  end

  return _M.store(self, key, req_obj, req_ttl)
end

--- Marks all entries as expired and remove them from Redis
-- @param free_mem Boolean indicating whether to free the memory; if false,
--   entries will only be marked as expired (not used for Redis)
-- @return true on success, nil plus error message otherwise
function _M:flush(free_mem)
  local red, err = get_redis_connection(self.opts)
  if not red then
    return nil, err or "failed to connect to Redis"
  end

  local key_prefix = get_key_prefix(self.opts)
  -- Use SCAN to find all keys with the prefix and delete them
  -- This is safer than using KEYS which can block Redis
  local cursor = "0"
  local deleted_count = 0

  repeat
    local result, err = red:scan(cursor, "match", key_prefix .. "*", "count", 100)
    if err then
      local keepalive_ok, keepalive_err = red:set_keepalive(10000, 100)
      if not keepalive_ok then
        kong.log.err("failed to set Redis keepalive: ", keepalive_err)
      end
      return nil, err
    end

    if result and type(result) == "table" then
      cursor = result[1]
      local keys = result[2]

      if keys and #keys > 0 then
        local ok, err = red:del(unpack(keys))
        if err then
          local keepalive_ok, keepalive_err = red:set_keepalive(10000, 100)
          if not keepalive_ok then
            kong.log.err("failed to set Redis keepalive: ", keepalive_err)
          end
          return nil, err
        end
        deleted_count = deleted_count + (ok or 0)
      end
    else
      break
    end
  until cursor == "0"

  local keepalive_ok, keepalive_err = red:set_keepalive(10000, 100)
  if not keepalive_ok then
    kong.log.err("failed to set Redis keepalive: ", keepalive_err)
  end

  return true
end

return _M
