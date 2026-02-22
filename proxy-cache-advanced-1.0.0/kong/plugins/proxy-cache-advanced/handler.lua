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
local CACHE_VERSION = 1
local EMPTY = {}


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
  do
    local method = kong.request.get_method()
    local method_match = false
    for i = 1, #conf.request_method do
      if conf.request_method[i] == method then
        method_match = true
        break
      end
    end

    if not method_match then
      return false
    end
  end

  -- 检查显式禁止指令
  -- TODO 注意 no-cache 在此处并不完全准确
  if conf.cache_control and (cc["no-store"] or cc["no-cache"] or
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

    local t, subtype, params = parse_mime_type(content_type)
    local content_match = false
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

    if not content_match then
      return false
    end
  end

  if conf.cache_control and (cc["private"] or cc["no-store"] or cc["no-cache"])
  then
    return false
  end

  if conf.cache_control and resource_ttl(cc) <= 0 then
    return false
  end

  return true
end


-- 指示应尝试缓存此请求的响应
local function signal_cache_req(ctx, cache_key, cache_status)
  ctx.proxy_cache = {
    cache_key = cache_key,
  }

  kong.response.set_header("X-Cache-Status", cache_status or "Miss")
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
    kong.log.err("handling purge of '", data, "'")

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

  local cache_key, err = cache_key.build_cache_key(consumer and consumer.id,
                                                   route    and route.id,
                                                   kong.request.get_method(),
                                                   uri,
                                                   kong.request.get_query(),
                                                   kong.request.get_headers(),
                                                   conf)
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

    ctx.req_body = kong.request.get_raw_body()

    -- 此请求可缓存但未在数据存储中找到
    -- 记录应在稍后将其存入缓存，并将请求传递给上游
    return signal_cache_req(ctx, cache_key)

  elseif err then
    kong.log.err(err)
    return
  end

  if res.version ~= CACHE_VERSION then
    kong.log.notice("cache format mismatch, purging ", cache_key)
    strategy:purge(cache_key)
    return signal_cache_req(ctx, cache_key, "Bypass")
  end

  -- 判断客户端是否会接受我们的缓存值
  if conf.cache_control then
    if cc["max-age"] and time() - res.timestamp > cc["max-age"] then
      return signal_cache_req(ctx, cache_key, "Refresh")
    end

    if cc["max-stale"] and time() - res.timestamp - res.ttl > cc["max-stale"]
    then
      return signal_cache_req(ctx, cache_key, "Refresh")
    end

    if cc["min-fresh"] and res.ttl - (time() - res.timestamp) < cc["min-fresh"]
    then
      return signal_cache_req(ctx, cache_key, "Refresh")
    end

  else
    -- 不提供过期数据；响应可能已存储最多 `conf.storage_ttl` 秒
    if time() - res.timestamp > conf.cache_ttl then
      return signal_cache_req(ctx, cache_key, "Refresh")
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
    proxy_cache.res_ttl = conf.cache_control and resource_ttl(cc) or conf.cache_ttl

  else
    kong.response.set_header("X-Cache-Status", "Bypass")
    ctx.proxy_cache = nil
  end

  -- TODO 处理 Vary 头
end


function ProxyCacheAdvancedHandler:body_filter(conf)
  local ctx = kong.ctx.plugin
  local proxy_cache = ctx.proxy_cache
  if not proxy_cache then
    return
  end

  local body = kong.response.get_raw_body()
  if body then
    local body_size = #body

    -- 检查响应 body 大小是否超过限制
    if conf.max_body_size and conf.max_body_size > 0 and body_size > conf.max_body_size then
      kong.log.debug("response body size (", body_size, " bytes) exceeds max_body_size (", conf.max_body_size, " bytes), skipping cache")
      ctx.proxy_cache = nil
      return
    end

    local res = {
      status    = kong.response.get_status(),
      headers   = proxy_cache.res_headers,
      body      = body,
      body_len  = #body,
      timestamp = time(),
      ttl       = proxy_cache.res_ttl,
      version   = CACHE_VERSION,
      req_body  = ctx.req_body,
    }

    local ttl = conf.storage_ttl or conf.cache_control and proxy_cache.res_ttl or
                conf.cache_ttl

    local strategy_name = conf.strategy
    local strategy_opts = conf[conf.strategy]
    local cache_key = proxy_cache.cache_key

    -- 在 body_filter 阶段 Kong 禁止网络 I/O（如 TCP/Redis），仅 memory 等本地策略可同步写缓存
    if strategies.LOCAL_DATA_STRATEGIES[strategy_name] then
      local strategy = require(STRATEGY_PATH)({
        strategy_name = strategy_name,
        strategy_opts = strategy_opts,
      })
      local ok, err = strategy:store(cache_key, res, ttl)
      if not ok then
        kong.log(err)
      elseif strategy_name == "disk" and ttl and ttl > 0 then
        -- disk 策略：延时 TTL 后执行清理，删除该缓存文件
        local delay_sec = ttl
        local opts = strategy_opts
        local key = cache_key
        local timer_ok, timer_err = ngx.timer.at(delay_sec, function(premature)
          if premature then
            return
          end
          local disk_strategy = require(STRATEGY_PATH)({
            strategy_name = "disk",
            strategy_opts = opts,
          })
          local purge_ok, purge_err = disk_strategy:purge(key)
          if not purge_ok then
            kong.log.err("proxy-cache-advanced disk TTL purge failed: ", purge_err)
          end
        end)
        if not timer_ok then
          kong.log.err("proxy-cache-advanced failed to create disk TTL purge timer: ", timer_err)
        end
      end
    else
      -- Redis 等需网络 I/O 的策略：推迟到 timer 中执行（timer 阶段允许 TCP）
      local ok, err = ngx.timer.at(0, function(premature)
        if premature then
          return
        end
        local strategy = require(STRATEGY_PATH)({
          strategy_name = strategy_name,
          strategy_opts = strategy_opts,
        })
        local store_ok, store_err = strategy:store(cache_key, res, ttl)
        if not store_ok then
          kong.log.err("proxy-cache-advanced redis store: ", store_err)
        end
      end)
      if not ok then
        kong.log.err("proxy-cache-advanced failed to create timer for cache store: ", err)
      end
    end
  end
end


return ProxyCacheAdvancedHandler
