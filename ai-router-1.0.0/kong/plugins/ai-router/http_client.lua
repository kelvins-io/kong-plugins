local http = require "resty.http"
local cjson = require "cjson.safe"
local sse_usage = require "kong.plugins.ai-router.sse_usage"

local ngx = ngx
local type = type
local tostring = tostring
local pairs = pairs
local tonumber = tonumber


local _M = {}


local HOP_BY_HOP = {
  ["connection"] = true,
  ["keep-alive"] = true,
  ["proxy-authenticate"] = true,
  ["proxy-authorization"] = true,
  ["te"] = true,
  ["trailers"] = true,
  ["transfer-encoding"] = true,
  ["upgrade"] = true,
  ["content-length"] = true,
}


local DEFAULT_KA_TIMEOUT = 60000
local DEFAULT_KA_POOL = 128


function _M.filter_response_headers(headers)
  local out = {}
  if type(headers) ~= "table" then
    return out
  end
  for k, v in pairs(headers) do
    if type(k) == "string" and not HOP_BY_HOP[k:lower()] then
      out[k] = v
    end
  end
  return out
end


local function parse_url(url)
  local m = ngx.re.match(url, [[^(https?)://([^:/]+)(?::(\d+))?(.*)$]], "jo")
  if not m then
    return nil, "invalid url: " .. tostring(url)
  end
  local scheme = m[1]
  local host = m[2]
  local port = tonumber(m[3]) or (scheme == "https" and 443 or 80)
  local path = m[4]
  if not path or path == "" then
    path = "/"
  end
  return {
    scheme = scheme,
    host = host,
    port = port,
    path = path,
  }
end


--- Normalize timeouts.
--- Accepts a number (legacy: read-only, connect/send use defaults) or a table:
---   { connect = ms, send = ms, read = ms }
---   aliases: connect_timeout / send_timeout / timeout|read_timeout
function _M.normalize_timeouts(timeouts)
  local connect_ms, send_ms, read_ms = 2000, 10000, 60000
  if type(timeouts) == "number" then
    read_ms = timeouts
  elseif type(timeouts) == "table" then
    connect_ms = tonumber(timeouts.connect or timeouts.connect_timeout) or connect_ms
    send_ms = tonumber(timeouts.send or timeouts.send_timeout) or send_ms
    read_ms = tonumber(timeouts.read or timeouts.read_timeout or timeouts.timeout) or read_ms
  end
  if connect_ms <= 0 then
    connect_ms = 2000
  end
  if send_ms <= 0 then
    send_ms = 10000
  end
  if read_ms <= 0 then
    read_ms = 60000
  end
  return connect_ms, send_ms, read_ms
end


local function keepalive_opts(opts)
  opts = opts or {}
  local timeout = tonumber(opts.keepalive_timeout) or DEFAULT_KA_TIMEOUT
  local pool = tonumber(opts.keepalive_pool_size) or DEFAULT_KA_POOL
  if timeout <= 0 then
    timeout = DEFAULT_KA_TIMEOUT
  end
  if pool <= 0 then
    pool = DEFAULT_KA_POOL
  end
  return timeout, pool
end


local function apply_timeouts(client, timeouts)
  local connect_ms, send_ms, read_ms = _M.normalize_timeouts(timeouts)
  client:set_timeouts(connect_ms, send_ms, read_ms)
  return connect_ms, send_ms, read_ms
end


local function put_keepalive(client, opts)
  local timeout, pool = keepalive_opts(opts)
  local ok, err = client:set_keepalive(timeout, pool)
  if not ok then
    client:close()
    return nil, err
  end
  return true
end


local function ssl_verify_of(opts)
  if opts and opts.ssl_verify ~= nil then
    return opts.ssl_verify and true or false
  end
  return true
end


local function connect(client, parsed, opts)
  local _, pool_size = keepalive_opts(opts)
  local pool = parsed.host .. ":" .. tostring(parsed.port) .. ":" .. parsed.scheme
  local verify = ssl_verify_of(opts)

  -- Reuse pool by name when supported; fall back to host,port.
  local ok, err = client:connect({
    host = parsed.host,
    port = parsed.port,
    pool = pool,
    pool_size = pool_size,
  })
  if not ok then
    ok, err = client:connect(parsed.host, parsed.port)
  end
  if not ok then
    return nil, "connect failed: " .. tostring(err)
  end

  if parsed.scheme == "https" then
    local _, serr = client:ssl_handshake(nil, parsed.host, verify)
    if serr then
      client:close()
      return nil, "ssl handshake failed: " .. tostring(serr)
    end
  end
  return true
end


--- Non-streaming. Returns status, headers, body, err
--- timeouts: number (read) or {connect,send,read}
--- opts: { keepalive_timeout, keepalive_pool_size, ssl_verify }
function _M.request(req, timeouts, opts)
  local client = http.new()
  apply_timeouts(client, timeouts)

  local ka_timeout, ka_pool = keepalive_opts(opts)
  local verify = ssl_verify_of(opts)
  local res, err = client:request_uri(req.url, {
    method = req.method or "POST",
    headers = req.headers,
    body = req.body,
    ssl_verify = verify,
    keepalive = true,
    keepalive_timeout = ka_timeout,
    keepalive_pool = ka_pool,
  })
  if not res then
    return nil, nil, nil, "request failed: " .. tostring(err)
  end

  return res.status, res.headers, res.body, nil
end


--- Streaming success path writes to the client.
--- On upstream error before body: returns status, headers, body (for retry).
--- On transport error: returns nil, nil, err_string.
--- On success: returns status, headers, nil, usage{prompt_tokens,completion_tokens}
--- timeouts: number (read) or {connect,send,read}; read applies per socket read chunk.
--- opts: { keepalive_timeout, keepalive_pool_size, ssl_verify }
function _M.stream_request(req, timeouts, on_headers, opts)
  -- Back-compat: older callers passed (req, timeouts, on_headers)
  if type(on_headers) == "table" and opts == nil then
    opts = on_headers
    on_headers = nil
  end

  local parsed, err = parse_url(req.url)
  if not parsed then
    return nil, nil, err
  end

  local client = http.new()
  apply_timeouts(client, timeouts)

  local ok, cerr = connect(client, parsed, opts)
  if not ok then
    return nil, nil, cerr
  end

  local res, rerr = client:request({
    method = req.method or "POST",
    path = parsed.path,
    headers = req.headers,
    body = req.body,
  })
  if not res then
    client:close()
    return nil, nil, "request failed: " .. tostring(rerr)
  end

  local resp_headers = _M.filter_response_headers(res.headers)

  if res.status < 200 or res.status >= 300 then
    local body = res:read_body()
    client:close()
    return res.status, resp_headers, body
  end

  if on_headers then
    on_headers(res.status, resp_headers)
  end

  local usage_state = sse_usage.new()
  local reader = res.body_reader
  if not reader then
    local body = res:read_body() or ""
    sse_usage.feed(usage_state, body)
    ngx.print(body)
    ngx.flush(true)
    put_keepalive(client, opts)
    local pt, ct = sse_usage.finish(usage_state)
    return res.status, resp_headers, nil, {
      prompt_tokens = pt,
      completion_tokens = ct,
    }
  end

  while true do
    local chunk, cherr = reader(8192)
    if cherr then
      client:close()
      local pt, ct = sse_usage.finish(usage_state)
      return res.status, resp_headers, "stream read failed: " .. tostring(cherr), {
        prompt_tokens = pt,
        completion_tokens = ct,
      }
    end
    if not chunk then
      break
    end
    sse_usage.feed(usage_state, chunk)
    ngx.print(chunk)
    ngx.flush(true)
  end

  put_keepalive(client, opts)
  local pt, ct = sse_usage.finish(usage_state)
  return res.status, resp_headers, nil, {
    prompt_tokens = pt,
    completion_tokens = ct,
  }
end


function _M.is_retryable(status, body)
  if not status then
    return true
  end
  if status == 408 or status == 409 or status == 429 then
    return true
  end
  if status >= 500 then
    return true
  end
  if status == 400 and type(body) == "string" then
    local l = body:lower()
    if l:find("overloaded", 1, true) or l:find("try again", 1, true) then
      return true
    end
  end
  return false
end


--- True when failure is connect/SSL — already waited connect_timeout; skip extra backoff.
function _M.is_connect_error(err)
  if type(err) ~= "string" then
    return false
  end
  local l = err:lower()
  return l:find("connect failed", 1, true) ~= nil
    or l:find("ssl handshake", 1, true) ~= nil
    or l:find("connection refused", 1, true) ~= nil
    or l:find("no route to host", 1, true) ~= nil
end


function _M.error_json(status, message, model)
  return cjson.encode({
    error = {
      message = message,
      type = "ai_router_error",
      param = model,
      code = status,
    },
  })
end


return _M
