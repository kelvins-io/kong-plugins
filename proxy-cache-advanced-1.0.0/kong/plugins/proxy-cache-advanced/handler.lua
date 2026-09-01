local require     = require
local cache_key   = require "kong.plugins.proxy-cache-advanced.cache_key"
local utils       = require "kong.tools.utils"
local kong_meta   = require "kong.meta"
local mime_type   = require "kong.tools.mime_type"
local nkeys       = require "table.nkeys"


local ngx              = ngx
local kong             = kong
local type             = type
local pairs            = pairs
local tostring         = tostring
local tonumber         = tonumber
local max              = math.max
local floor            = math.floor
local lower            = string.lower
local find             = string.find
local concat           = table.concat
local time             = ngx.time
local resp_get_headers = ngx.resp and ngx.resp.get_headers
local ngx_re_gmatch    = ngx.re.gmatch
local ngx_re_sub       = ngx.re.gsub
local ngx_re_match     = ngx.re.match
local parse_http_time  = ngx.parse_http_time
local parse_mime_type  = mime_type.parse_mime_type


local tab_new = require("table.new")


local strategies   = require "kong.plugins.proxy-cache-advanced.strategies"
local STRATEGY_PATH = "kong.plugins.proxy-cache-advanced.strategies"
local lock_redis   = require "kong.plugins.proxy-cache-advanced.lock_redis"
local lock_shm     = require "kong.plugins.proxy-cache-advanced.lock_shm"
local CACHE_VERSION = 1
local EMPTY = {}


local function cache_lock_enabled(lock_conf)
  return lock_conf and (lock_conf.enable_cache_lock == true or lock_conf.enable_cache_lock == "true")
end


local function get_lock_backend(conf)
  if strategies.LOCAL_DATA_STRATEGIES[conf.strategy] then
    if cache_lock_enabled(conf.lock_shm) then
      return "shm", conf.lock_shm
    end
    return nil
  end

  if cache_lock_enabled(conf.lock_redis) then
    return "redis", conf.lock_redis
  end
  return nil
end


local function new_lock_client(backend, lock_conf)
  if backend == "shm" then
    return lock_shm.new(lock_conf)
  end
  if backend == "redis" then
    return lock_redis.new(lock_conf)
  end
  return nil, "unknown lock backend"
end


local function release_cache_lock(backend, lock_conf, cache_key, lock_token)
  if not lock_token or not lock_conf then
    return
  end

  local lock_client = new_lock_client(backend, lock_conf)
  if lock_client then
    lock_client:release_lock(cache_key, lock_token)
  end
end


local function is_llm_enabled(conf)
  return conf.llm and (conf.llm.enable == true or conf.llm.enable == "true")
end


local function is_json_content_type(ct)
  if type(ct) == "table" then
    ct = ct[1]
  end
  if type(ct) ~= "string" or ct == "" then
    return false
  end
  return find(lower(ct), "application/json", 1, true) ~= nil
end


local function is_sse_content_type(ct)
  if type(ct) == "table" then
    ct = ct[1]
  end
  if type(ct) ~= "string" or ct == "" then
    return false
  end
  ct = lower(ct)
  local semi = find(ct, ";", 1, true)
  if semi then
    ct = ct:sub(1, semi - 1)
  end
  ct = ct:match("^%s*(.-)%s*$") or ct
  return ct == "text/event-stream"
end


local function abandon_cache_req(ctx)
  local proxy_cache = ctx.proxy_cache
  if not proxy_cache then
    return
  end

  local token = proxy_cache.lock_token
  local backend = proxy_cache.lock_backend
  local lock_conf = proxy_cache.lock_conf
  local key = proxy_cache.cache_key
  ctx.proxy_cache = nil

  if not token then
    return
  end

  -- header/body_filter 禁止 Redis 网络 I/O；shm 可同步释放
  if backend == "shm" then
    release_cache_lock(backend, lock_conf, key, token)
    return
  end

  local ok, err = ngx.timer.at(0, function(premature)
    if premature then
      return
    end
    release_cache_lock(backend, lock_conf, key, token)
  end)
  if not ok then
    kong.log.err("proxy-cache-advanced failed to create timer for lock release: ", err)
  end
end

-- Redis 等远程策略异步 store 使用 kong.tools.queue（按需加载）
local Queue
local function get_queue()
  if not Queue then
    Queue = require "kong.tools.queue"
  end
  return Queue
end

-- 供 kong.tools.queue 调用的批量 store 处理函数；成功返回 true，失败返回 false, err
local function remote_store_handler(handler_conf, entries)
  local path = handler_conf.STRATEGY_PATH
  for _, entry in ipairs(entries) do
    if entry._dummy then
      -- 占位条目，跳过
    else
      local strategy = require(path)({
        strategy_name = entry.strategy_name,
        strategy_opts = entry.strategy_opts,
      })
      local ok, err = strategy:store(entry.cache_key, entry.res, entry.ttl)
      if not ok then
        return false, err
      end
      -- 防击穿锁：store 成功后释放（远程策略使用 lock_redis）
      if entry.lock_token and entry.lock_backend == "redis" and entry.lock_conf then
        release_cache_lock(entry.lock_backend, entry.lock_conf, entry.cache_key, entry.lock_token)
      end
    end
  end
  return true
end

-- 根据 conf 构建 queue_conf（Kong 3.4.x kong.tools.queue）
local function build_queue_conf(conf)
  local q = get_queue()
  local queue_conf = q.get_plugin_params("proxy-cache-advanced", conf, "proxy-cache-advanced-store")
  queue_conf.max_batch_size       = 100
  queue_conf.max_coalescing_delay = 1
  queue_conf.max_entries          = 10000
  queue_conf.max_retry_time       = 60
  queue_conf.initial_retry_delay  = 0.01
  queue_conf.max_retry_delay      = 60
  return queue_conf
end

-- http://www.w3.org/Protocols/rfc2616/rfc2616-sec13.html#sec13.5.1
-- 注意 content-length 并非严格意义上的逐跳头，但我们仍会在此处调整它
local hop_by_hop_headers = {
  ["connection"]          = true,
  ["keep-alive"]          = true,
  ["proxy-authenticate"]  = true,
  ["proxy-authorization"] = true,
  ["te"]                  = true,
  ["trailers"]            = true,
  ["transfer-encoding"]   = true,
  ["upgrade"]             = true,
  ["content-length"]      = true,
}


local function overwritable_header(header)
  local n_header = lower(header)

  return not hop_by_hop_headers[n_header]
     and not ngx_re_match(n_header, "ratelimit-remaining")
end


local function parse_directive_header(h)
  if not h then
    return EMPTY
  end

  if type(h) == "table" then
    h = concat(h, ", ")
  end

  local t    = {}
  local res  = tab_new(3, 0)
  local iter = ngx_re_gmatch(h, "([^,]+)", "oj")

  local m = iter()
  while m do
    local _, err = ngx_re_match(m[0], [[^\s*([^=]+)(?:=(.+))?]],
                                "oj", nil, res)
    if err then
      kong.log.err(err)
    end

    -- 若指令令牌看起来像数字，则存储为数值；否则存储字符串值
    -- 对于没有令牌的指令，我们将键设置为 true
    t[lower(res[1])] = tonumber(res[2]) or res[2] or true

    m = iter()
  end

  return t
end


local function req_cc()
  return parse_directive_header(ngx.var.http_cache_control)
end


local function res_cc()
  return parse_directive_header(ngx.var.sent_http_cache_control)
end


local function resource_ttl(res_cc)
  local max_age = res_cc["s-maxage"] or res_cc["max-age"]

  if not max_age then
    local expires = ngx.var.sent_http_expires

    -- 若存在多个 Expires 头，最后一个生效
    if type(expires) == "table" then
      expires = expires[#expires]
    end

    local exp_time = parse_http_time(tostring(expires))
    if exp_time then
      max_age = exp_time - time()
    end
  end

  return max_age and max(max_age, 0) or 0
end


local function cacheable_request(conf, cc)
  -- TODO 将这些搜索重构为 O(1) 复杂度
  local llm_on = is_llm_enabled(conf)
  do
    local method = kong.request.get_method()
    local method_match = false
    for i = 1, #conf.request_method do
      if conf.request_method[i] == method then
        method_match = true
        break
      end
    end

    -- LLM 接口几乎都是 POST；开启 llm 时允许 POST 即使未写入 request_method
    if not method_match and not (llm_on and method == "POST") then
      return false
    end
  end

  -- 检查显式禁止指令
  -- TODO 注意 no-cache 在此处并不完全准确
  -- LLM 请求通常带 Authorization，客户端/SSE 也常带 no-cache；开启 llm 时不因此跳过
  if not llm_on and conf.cache_control and (cc["no-store"] or cc["no-cache"] or
     ngx.var.authorization) then
    return false
  end

  return true
end


local function cacheable_response(conf, cc)
  -- TODO 将这些搜索重构为 O(1) 复杂度
  do
    local status = kong.response.get_status()
    local status_match = false
    for i = 1, #conf.response_code do
      if conf.response_code[i] == status then
        status_match = true
        break
      end
    end

    if not status_match then
      return false
    end
  end

  do
    local content_type = ngx.var.sent_http_content_type

    -- 若无法检查此内容类型，则退出
    if not content_type or type(content_type) == "table" or
       content_type == "" then

      return false
    end

    -- 开启 llm 时 text/event-stream 视为可缓存，无需写入 content_type 白名单
    local content_match = is_llm_enabled(conf) and is_sse_content_type(content_type)
    if not content_match then
      local t, subtype, params = parse_mime_type(content_type)
      for i = 1, #conf.content_type do
        local expected_ct = conf.content_type[i]
        local exp_type, exp_subtype, exp_params = parse_mime_type(expected_ct)
        if exp_type then
          if (exp_type == "*" or t == exp_type) and
            (exp_subtype == "*" or subtype == exp_subtype) then
            local params_match = true
            for key, value in pairs(exp_params or EMPTY) do
              if value ~= (params or EMPTY)[key] then
                params_match = false
                break
              end
            end
            if params_match and
              (nkeys(params or EMPTY) == nkeys(exp_params or EMPTY)) then
              content_match = true
              break
            end
          end
        end
      end
    end

    if not content_match then
      return false
    end
  end

  -- LLM/SSE 上游常带 Cache-Control: no-cache，开启 llm 时不按 RFC 拦截
  if not is_llm_enabled(conf) then
    if conf.cache_control and (cc["private"] or cc["no-store"] or cc["no-cache"])
    then
      return false
    end

    if conf.cache_control and resource_ttl(cc) <= 0 then
      return false
    end
  end

  return true
end


-- 指示应尝试缓存此请求的响应（lock_token 用于防击穿，store 成功后释放）
local function signal_cache_req(ctx, cache_key, cache_status, lock_token, lock_backend, lock_conf)
  ctx.proxy_cache = {
    cache_key = cache_key,
    lock_token = lock_token,
    lock_backend = lock_backend,
    lock_conf = lock_conf,
  }

  kong.response.set_header("X-Cache-Status", cache_status or "Miss")
end


-- 当需要回源时：memory/disk 使用 lock_shm（resty.lock），远程策略使用 lock_redis
-- 返回 "go" 表示放行上游；返回 "hit", res 表示已从缓存返回，调用方需执行 kong.response.exit(res...)
local function try_go_upstream_with_lock(conf, ctx, strategy, cache_key, cache_status, cc)
  local lock_backend, lock_conf = get_lock_backend(conf)
  if not lock_backend then
    return "go"
  end

  local lock_ttl = lock_conf.cache_lock_ttl or 10
  local retry_count = lock_conf.cache_lock_retry_count or 50
  local retry_delay = lock_conf.cache_lock_retry_delay or 0.1

  local lock_client, err = new_lock_client(lock_backend, lock_conf)
  if not lock_client then
    kong.log.err("proxy-cache-advanced lock client init failed: ", err)
    return "go"
  end
  local token = lock_client:acquire_lock(cache_key, lock_ttl)
  if token then
    -- 当前请求作为回源者，放行上游并在 store 后释放锁
    return "go", token, lock_backend, lock_conf
  end

  -- 未抢到锁：等待其他请求回源并写入缓存，重试 fetch
  for _ = 1, retry_count do
    ngx.sleep(retry_delay)
    local res, err = strategy:fetch(cache_key)
    if not err and res and res.version == CACHE_VERSION then
      local skip_refresh = true
      if conf.cache_control and cc then
        if cc["max-age"] and time() - res.timestamp > cc["max-age"] then
          skip_refresh = false
        elseif cc["max-stale"] and time() - res.timestamp - res.ttl > cc["max-stale"] then
          skip_refresh = false
        elseif cc["min-fresh"] and res.ttl - (time() - res.timestamp) < cc["min-fresh"] then
          skip_refresh = false
        end
      else
        if time() - res.timestamp > conf.cache_ttl then
          skip_refresh = false
        end
      end
      if skip_refresh then
        return "hit", res
      end
    end
  end

  -- 重试耗尽仍未命中，放行上游（避免无限等待）
  return "go"
end


-- 将完整响应写入缓存（body_filter 末包或 SSE 流结束后调用）
local function persist_cache(conf, ctx, proxy_cache, body)
  local body_size = #body

  if conf.max_body_size and conf.max_body_size > 0 and body_size > conf.max_body_size then
    kong.log.debug("response body size (", body_size, " bytes) exceeds max_body_size (",
                   conf.max_body_size, " bytes), skipping cache")
    abandon_cache_req(ctx)
    return
  end

  local res = {
    status    = kong.response.get_status(),
    headers   = proxy_cache.res_headers,
    body      = body,
    body_len  = body_size,
    timestamp = time(),
    ttl       = proxy_cache.res_ttl,
    version   = CACHE_VERSION,
    req_body  = ctx.req_body,
  }

  local ttl = conf.storage_ttl or conf.cache_control and proxy_cache.res_ttl or
              conf.cache_ttl

  local strategy_name = conf.strategy
  local strategy_opts = conf[conf.strategy]
  local key = proxy_cache.cache_key

  -- 在 body_filter 阶段 Kong 禁止网络 I/O（如 TCP/Redis），仅 memory 等本地策略可同步写缓存
  if strategies.LOCAL_DATA_STRATEGIES[strategy_name] then
    local strategy = require(STRATEGY_PATH)({
      strategy_name = strategy_name,
      strategy_opts = strategy_opts,
    })
    local ok, err = strategy:store(key, res, ttl)
    if not ok then
      kong.log(err)
    else
      if proxy_cache.lock_token and proxy_cache.lock_backend == "shm" and proxy_cache.lock_conf then
        release_cache_lock(proxy_cache.lock_backend, proxy_cache.lock_conf, key, proxy_cache.lock_token)
      end
      if strategy_name == "disk" and ttl and ttl > 0 then
        -- disk 策略：延时 TTL 后执行清理，删除该缓存文件，ngx.timer延迟删除耗费cpu推荐使用独立的删除程序定期清理
      end
    end
    return
  end

  -- Redis 等需网络 I/O 的策略：优先用 kong.tools.queue 批量写，不可用时回退到 timer
  local use_timer = true
  local ok_load, q = pcall(get_queue)
  if ok_load and q then
    local queue_conf = build_queue_conf(conf)
    local handler_conf = { STRATEGY_PATH = STRATEGY_PATH }
    local ok_enq, err_enq = q.enqueue(queue_conf, remote_store_handler, handler_conf, {
      strategy_name = strategy_name,
      strategy_opts = strategy_opts,
      cache_key = key,
      res = res,
      ttl = ttl,
      lock_token = proxy_cache.lock_token,
      lock_backend = proxy_cache.lock_backend,
      lock_conf = proxy_cache.lock_conf,
    })
    if ok_enq then
      use_timer = false
    else
      kong.log.warn("proxy-cache-advanced queue enqueue failed, falling back to timer: ", err_enq)
    end
  else
    kong.log.warn("proxy-cache-advanced kong.tools.queue not available, using timer: ", q)
  end
  if use_timer then
    local lock_token = proxy_cache.lock_token
    local lock_backend = proxy_cache.lock_backend
    local lock_conf = proxy_cache.lock_conf
    local ok, err = ngx.timer.at(0, function(premature)
      if premature then
        return
      end
      local strategy = require(STRATEGY_PATH)({
        strategy_name = strategy_name,
        strategy_opts = strategy_opts,
      })
      local store_ok, store_err = strategy:store(key, res, ttl)
      if not store_ok then
        kong.log.err("proxy-cache-advanced redis store: ", store_err)
      elseif lock_token and lock_backend == "redis" and lock_conf then
        release_cache_lock(lock_backend, lock_conf, key, lock_token)
      end
    end)
    if not ok then
      kong.log.err("proxy-cache-advanced failed to create timer for cache store: ", err)
    end
  end
end


local ProxyCacheAdvancedHandler = {
  VERSION = kong_meta.version,
  PRIORITY = 101,
}


function ProxyCacheAdvancedHandler:init_worker()
  -- 接收来自其他节点的通知，表示我们已清除某个缓存条目
  -- 仅需一个 worker 处理此类清除操作
  -- 如果/当我们引入内联 LRU 缓存时，也需要涉及 worker 事件
  local unpack = unpack

  kong.cluster_events:subscribe("proxy-cache-advanced:purge", function(data)
    kong.log.debug("handling purge of '", data, "'")

    local plugin_id, cache_key = unpack(utils.split(data, ":"))
    local plugin, err = kong.db.plugins:select({
      id = plugin_id,
    })
    if err then
      kong.log.err("error in retrieving plugins: ", err)
      return
    end

    local strategy = require(STRATEGY_PATH)({
      strategy_name = plugin.config.strategy,
      strategy_opts = plugin.config[plugin.config.strategy],
    })

    if cache_key ~= "nil" then
      local ok, err = strategy:purge(cache_key)
      if not ok then
        kong.log.err("failed to purge cache key '", cache_key, "': ", err)
        return
      end

    else
      local ok, err = strategy:flush(true)
      if not ok then
        kong.log.err("error in flushing cache data: ", err)
      end
    end
  end)
end


function ProxyCacheAdvancedHandler:access(conf)
  local cc = req_cc()

  -- 若已知此请求不可缓存，则退出
  if not cacheable_request(conf, cc) then
    kong.response.set_header("X-Cache-Status", "Bypass")
    return
  end

  local ctx = kong.ctx.plugin
  local consumer = kong.client.get_consumer()
  local route = kong.router.get_route()
  local uri = ngx_re_sub(ngx.var.request, "\\?.*", "", "oj")

  -- 若希望缓存键的 URI 仅为小写
  if conf.ignore_uri_case then
    uri = lower(uri)
  end

  local headers = kong.request.get_headers()
  local llm_digest
  local req_body
  if is_llm_enabled(conf) then
    req_body = kong.request.get_raw_body()
    if is_json_content_type(headers["content-type"]) then
      llm_digest = cache_key.llm_digest(req_body, conf.llm)
    else
      kong.log.debug("proxy-cache-advanced llm: skip llm key dimensions, request is not JSON")
    end
  end

  local cache_key, err = cache_key.build_cache_key(consumer and consumer.id,
                                                   route    and route.id,
                                                   kong.request.get_method(),
                                                   uri,
                                                   kong.request.get_query(),
                                                   headers,
                                                   conf,
                                                   llm_digest)
  if err then
    kong.log.err(err)
    return
  end

  kong.response.set_header("X-Cache-Key", cache_key)

  -- 尝试从计算出的缓存键获取缓存对象
  local strategy = require(STRATEGY_PATH)({
    strategy_name = conf.strategy,
    strategy_opts = conf[conf.strategy],
  })

  local res, err = strategy:fetch(cache_key)
  if err == "request object not in cache" then -- TODO 将其改为 utils 枚举错误

    -- 此请求在数据存储中未找到，但客户端仅需要缓存数据
    -- 参见 https://tools.ietf.org/html/rfc7234#section-5.2.1.7
    if conf.cache_control and cc["only-if-cached"] then
      return kong.response.exit(ngx.HTTP_GATEWAY_TIMEOUT)
    end

    ctx.req_body = req_body or kong.request.get_raw_body()

    local action, token, lock_backend, lock_conf = try_go_upstream_with_lock(conf, ctx, strategy, cache_key, "Miss", cc)
    if action == "hit" then
      res = token
      -- 跳转到下方统一缓存命中出口
    else
      signal_cache_req(ctx, cache_key, "Miss", token, lock_backend, lock_conf)
      return
    end

  elseif err then
    kong.log.err(err)
    return
  end

  if res.version ~= CACHE_VERSION then
    kong.log.notice("cache format mismatch, purging ", cache_key)
    strategy:purge(cache_key)
    local action, token, lock_backend, lock_conf = try_go_upstream_with_lock(conf, ctx, strategy, cache_key, "Bypass", cc)
    if action == "hit" then
      res = token
    else
      signal_cache_req(ctx, cache_key, "Bypass", token, lock_backend, lock_conf)
      return
    end
  end

  -- 判断客户端是否会接受我们的缓存值
  if conf.cache_control then
    if cc["max-age"] and time() - res.timestamp > cc["max-age"] then
      local action, token, lock_backend, lock_conf = try_go_upstream_with_lock(conf, ctx, strategy, cache_key, "Refresh", cc)
      if action == "hit" then
        res = token
      else
        signal_cache_req(ctx, cache_key, "Refresh", token, lock_backend, lock_conf)
        return
      end
    end

    if cc["max-stale"] and time() - res.timestamp - res.ttl > cc["max-stale"] then
      local action, token, lock_backend, lock_conf = try_go_upstream_with_lock(conf, ctx, strategy, cache_key, "Refresh", cc)
      if action == "hit" then
        res = token
      else
        signal_cache_req(ctx, cache_key, "Refresh", token, lock_backend, lock_conf)
        return
      end
    end

    if cc["min-fresh"] and res.ttl - (time() - res.timestamp) < cc["min-fresh"] then
      local action, token, lock_backend, lock_conf = try_go_upstream_with_lock(conf, ctx, strategy, cache_key, "Refresh", cc)
      if action == "hit" then
        res = token
      else
        signal_cache_req(ctx, cache_key, "Refresh", token, lock_backend, lock_conf)
        return
      end
    end

  else
    -- 不提供过期数据；响应可能已存储最多 `conf.storage_ttl` 秒
    if time() - res.timestamp > conf.cache_ttl then
      local action, token, lock_backend, lock_conf = try_go_upstream_with_lock(conf, ctx, strategy, cache_key, "Refresh", cc)
      if action == "hit" then
        res = token
      else
        signal_cache_req(ctx, cache_key, "Refresh", token, lock_backend, lock_conf)
        return
      end
    end
  end

  -- 我们有缓存数据了！
  -- 为日志插件暴露响应数据
  local response_data = {
    res = res,
    req = {
      body = res.req_body,
    },
    server_addr = ngx.var.server_addr,
  }

  kong.ctx.shared.proxy_cache_hit = response_data

  local nctx = ngx.ctx
  nctx.KONG_PROXIED = true

  for k in pairs(res.headers) do
    if not overwritable_header(k) then
      res.headers[k] = nil
    end
  end

  res.headers["Age"] = floor(time() - res.timestamp)
  res.headers["X-Cache-Status"] = "Hit"

  return kong.response.exit(res.status, res.body, res.headers)
end


function ProxyCacheAdvancedHandler:header_filter(conf)
  local ctx = kong.ctx.plugin
  local proxy_cache = ctx.proxy_cache
  -- 在以下情况下不查看我们的头：
  -- a) 请求不可缓存，或
  -- b) 请求已从缓存中提供
  if not proxy_cache then
    return
  end

  local cc = res_cc()

  -- 若这是可缓存请求，收集头信息并标记
  if cacheable_response(conf, cc) then
    -- TODO: 是否应使用 kong.conf 配置的限制？
    proxy_cache.res_headers = resp_get_headers(0, true)
    -- LLM/SSE 常带 no-cache，TTL 使用插件 cache_ttl，避免被算成 0
    if is_llm_enabled(conf) then
      proxy_cache.res_ttl = conf.cache_ttl
    else
      proxy_cache.res_ttl = conf.cache_control and resource_ttl(cc) or conf.cache_ttl
    end
    proxy_cache.is_sse = is_sse_content_type(ngx.var.sent_http_content_type)

  else
    kong.response.set_header("X-Cache-Status", "Bypass")
    abandon_cache_req(ctx)
  end

  -- TODO 处理 Vary 头
end


function ProxyCacheAdvancedHandler:body_filter(conf)
  local ctx = kong.ctx.plugin
  local proxy_cache = ctx.proxy_cache
  if not proxy_cache then
    return
  end

  -- SSE：不要调用 get_raw_body()（它会把中间 chunk 置空，打断流式）。
  -- 首次 miss 原样透传 ngx.arg，流结束后再整包入库；命中走 access 的 exit 一次性回放。
  if proxy_cache.is_sse then
    local chunk = ngx.arg[1]
    local eof = ngx.arg[2]

    if type(chunk) == "string" and chunk ~= "" then
      local new_size = (proxy_cache.body_size or 0) + #chunk
      if conf.max_body_size and conf.max_body_size > 0 and new_size > conf.max_body_size then
        kong.log.debug("sse response body size exceeds max_body_size, skipping cache")
        abandon_cache_req(ctx)
        return
      end
      local buf = proxy_cache.body_chunks
      if not buf then
        buf = { n = 0 }
        proxy_cache.body_chunks = buf
      end
      buf.n = buf.n + 1
      buf[buf.n] = chunk
      proxy_cache.body_size = new_size
    end

    if not eof then
      return
    end

    local body = ""
    local buf = proxy_cache.body_chunks
    if buf and buf.n > 0 then
      body = concat(buf, "", 1, buf.n)
    end
    persist_cache(conf, ctx, proxy_cache, body)
    return
  end

  local body = kong.response.get_raw_body()
  if not body then
    return
  end

  persist_cache(conf, ctx, proxy_cache, body)
end


return ProxyCacheAdvancedHandler
