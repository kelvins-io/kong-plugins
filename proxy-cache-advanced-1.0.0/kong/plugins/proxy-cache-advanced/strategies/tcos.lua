---
--- Created by yq
--- DateTime: 2026/2/25 23:01
---

---
--- 腾讯云 COS（Cloud Object Storage）存储策略（策略关键字：tcos）
--- 使用 COS REST API：PUT/GET/DELETE Object，需网络 I/O，与 Redis 一样走 queue/timer 异步 store
---
local cjson = require "cjson.safe"
local http   = require "resty.http"
local ngx    = ngx
local type   = type
local time   = ngx.time
local setmetatable = setmetatable
local tostring = tostring
local format  = string.format
local gsub   = string.gsub
local sort   = table.sort
local concat = table.concat


local _M = {}

-- 连接超时 / 发送超时（秒）
local DEFAULT_TIMEOUT = 5
-- 签名有效时长（秒）
local SIGN_EXPIRE = 3600


--- 将缓存键转为 COS 对象键（安全字符）
local function cache_key_to_object_key(key)
  return ngx.md5(key)
end


--- URL 编码（COS 签名要求：特定字符需编码）
local function cos_url_encode(s)
  if not s or s == "" then
    return ""
  end
  s = tostring(s)
  local out = {}
  for i = 1, #s do
    local b = s:byte(i)
    if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 45 or b == 46 or b == 95 or b == 126 then
      out[#out + 1] = s:sub(i, i)
    else
      out[#out + 1] = format("%%%02X", b)
    end
  end
  return concat(out)
end


--- SHA1 十六进制（使用 OpenSSL FFI，OpenResty 环境通常有 libcrypto）
local function sha1_hex(input)
  local ffi = require "ffi"
  local ffi_str = ffi.string
  ffi.cdef[[
    unsigned char *SHA1(const unsigned char *d, unsigned long n, unsigned char *md);
  ]]
  local lib = ffi.load("crypto", true)
  if not lib then
    return nil, "failed to load libcrypto for SHA1"
  end
  local md = ffi.new("unsigned char[20]")
  local ok = lib.SHA1(input, #input, md)
  if ok == nil then
    return nil, "SHA1 failed"
  end
  local hex = {}
  for i = 0, 19 do
    hex[#hex + 1] = format("%02x", md[i])
  end
  return concat(hex)
end


--- HMAC-SHA1 十六进制
local function hmac_sha1_hex(secret_key, message)
  local ffi = require "ffi"
  ffi.cdef[[
    typedef struct evp_md_st EVP_MD;
    const EVP_MD *EVP_sha1(void);
    unsigned char *HMAC(const EVP_MD *evp_md, const void *key, int key_len,
                        const unsigned char *d, int n, unsigned char *md, unsigned int *md_len);
  ]]
  local lib = ffi.load("crypto", true)
  if not lib then
    return nil, "failed to load libcrypto for HMAC"
  end
  local evp_sha1 = lib.EVP_sha1()
  if evp_sha1 == nil then
    return nil, "EVP_sha1 failed"
  end
  local md = ffi.new("unsigned char[64]")
  local md_len = ffi.new("unsigned int[1]")
  local ok = lib.HMAC(evp_sha1, secret_key, #secret_key, message, #message, md, md_len)
  if ok == nil then
    return nil, "HMAC failed"
  end
  local len = md_len[0]
  local hex = {}
  for i = 0, len - 1 do
    hex[#hex + 1] = format("%02x", md[i])
  end
  return concat(hex)
end


--- 生成腾讯云 COS 请求签名（鉴权文档 https://cloud.tencent.com/document/product/436/7778）
-- @string secret_id   SecretId
-- @string secret_key  SecretKey
-- @string method     HTTP 方法（小写）
-- @string pathname   请求路径（如 /key 或 /）
-- @string host       请求 Host
-- @table  headers    参与签名的请求头（key 小写）
-- @table  params     URL 参数（key 小写）
-- @number key_time_start  签名起始时间戳
-- @number key_time_end    签名结束时间戳
local function build_cos_authorization(secret_id, secret_key, method, pathname, host, headers, params, key_time_start, key_time_end)
  local key_time = format("%d;%d", key_time_start, key_time_end)

  -- HttpParameters: 按 key 小写字典序，key=value&...（COS 签名要求 key 小写）
  local param_keys = {}
  for k in pairs(params or {}) do
    param_keys[#param_keys + 1] = k
  end
  sort(param_keys, function(a, b) return a:lower() < b:lower() end)
  local param_list = {}
  local param_str = {}
  for _, k in ipairs(param_keys) do
    param_list[#param_list + 1] = cos_url_encode(k:lower())
    param_str[#param_str + 1] = cos_url_encode(k:lower()) .. "=" .. cos_url_encode(tostring(params[k] or ""))
  end
  local http_params = concat(param_str, "&")
  local url_param_list = concat(param_list, ";")
  if url_param_list == "" then
    url_param_list = ""
  end

  -- HttpHeaders: 参与签名的头（host, date 等），按 key 字典序
  headers = headers or {}
  if not headers["host"] then
    headers["host"] = host
  end
  local header_keys = {}
  for k in pairs(headers) do
    header_keys[#header_keys + 1] = k:lower()
  end
  sort(header_keys)
  local header_str = {}
  local header_list = {}
  for _, k in ipairs(header_keys) do
    header_list[#header_list + 1] = cos_url_encode(k)
    header_str[#header_str + 1] = cos_url_encode(k) .. "=" .. cos_url_encode(tostring(headers[k] or ""))
  end
  local http_headers = concat(header_str, "&")
  local q_header_list = concat(header_list, ";")

  -- HttpString = method\npathname\nparams\nheaders\n
  local http_string = method:lower() .. "\n" .. pathname .. "\n" .. http_params .. "\n" .. http_headers .. "\n"
  local sha1_http, err_sha = sha1_hex(http_string)
  if not sha1_http then
    return nil, "sha1 of http string failed: " .. tostring(err_sha)
  end
  local string_to_sign = "sha1\n" .. key_time .. "\n" .. sha1_http .. "\n"
  local sign_key, err_hmac = hmac_sha1_hex(secret_key, key_time)
  if not sign_key then
    return nil, "hmac key failed: " .. tostring(err_hmac)
  end
  local signature, err_sig = hmac_sha1_hex(sign_key, string_to_sign)
  if not signature then
    return nil, "hmac signature failed: " .. tostring(err_sig)
  end

  return format("q-sign-algorithm=sha1&q-ak=%s&q-sign-time=%s&q-key-time=%s&q-header-list=%s&q-url-param-list=%s&q-signature=%s",
    cos_url_encode(secret_id), key_time, key_time, q_header_list, url_param_list, signature)
end


--- 发起 COS HTTP 请求（带签名）
local function cos_request(self, method, object_key, opts)
  opts = opts or {}
  local bucket = self.opts.bucket
  local region = self.opts.region or "ap-guangzhou"
  local host = self.opts.endpoint or format("%s.cos.%s.myqcloud.com", bucket, region)
  local prefix = (self.opts.key_prefix or "proxy-cache-advanced/"):gsub("^/+", ""):gsub("/+$", "")
  if prefix ~= "" then
    prefix = prefix .. "/"
  end
  local path_key = prefix .. object_key
  local pathname = "/" .. path_key
  local pathname_enc = "/" .. gsub(path_key, "([^/A-Za-z0-9_.%-~])", function(c)
    return format("%%%02X", c:byte(1))
  end)

  local key_start = opts.key_time_start or time()
  local key_end = opts.key_time_end or (key_start + SIGN_EXPIRE)
  local headers = {
    host = host,
    date = opts.date or ngx.http_time(ngx.time()),
  }
  for k, v in pairs(opts.extra_headers or {}) do
    headers[k:lower()] = v
  end
  local params = opts.params or {}
  local auth = build_cos_authorization(
    self.opts.secret_id,
    self.opts.secret_key,
    method,
    pathname,
    host,
    headers,
    params,
    key_start,
    key_end
  )
  if not auth then
    return nil, auth
  end
  headers["authorization"] = auth

  local timeout_ms = (self.opts.timeout or DEFAULT_TIMEOUT) * 1000
  local httpc = http:new()
  httpc:set_timeout(timeout_ms)
  local scheme = self.opts.scheme or "https"
  local url = scheme .. "://" .. host .. pathname_enc
  if next(params) then
    local q = {}
    for k, v in pairs(params) do
      q[#q + 1] = k .. "=" .. cos_url_encode(tostring(v))
    end
    url = url .. "?" .. concat(q, "&")
  end

  local req_headers = {
    ["Host"] = host,
    ["Date"] = headers["date"],
    ["Authorization"] = auth,
  }
  for k, v in pairs(opts.extra_headers or {}) do
    req_headers[k] = v
  end

  -- 为规避「self-signed certificate in certificate chain」等环境证书问题，可配置 ssl_verify = false
  local ssl_verify = self.opts.ssl_verify
  if ssl_verify == nil then
    ssl_verify = true
  end

  local res, err
  if method == "GET" then
    res, err = httpc:request_uri(url, { method = "GET", headers = req_headers, ssl_verify = ssl_verify })
  elseif method == "PUT" then
    res, err = httpc:request_uri(url, {
      method = "PUT",
      headers = req_headers,
      body = opts.body,
      ssl_verify = ssl_verify,
    })
  elseif method == "DELETE" then
    res, err = httpc:request_uri(url, { method = "DELETE", headers = req_headers, ssl_verify = ssl_verify })
  elseif method == "POST" then
    res, err = httpc:request_uri(url, {
      method = "POST",
      headers = req_headers,
      body = opts.body,
      ssl_verify = ssl_verify,
    })
  else
    return nil, "unsupported method " .. tostring(method)
  end

  if err then
    return nil, "COS request failed: " .. tostring(err)
  end
  if not res then
    return nil, "COS request returned no response"
  end
  return res, nil
end


--- 创建 tcos 策略实例
-- @table opts 配置：secret_id, secret_key, bucket, region[, key_prefix, timeout, endpoint, scheme]
function _M.new(opts)
  if not opts then
    return nil, "tcos options are required"
  end
  if not opts.secret_id or opts.secret_id == "" then
    return nil, "tcos.secret_id is required"
  end
  if not opts.secret_key or opts.secret_key == "" then
    return nil, "tcos.secret_key is required"
  end
  if not opts.bucket or opts.bucket == "" then
    return nil, "tcos.bucket is required"
  end
  local self = {
    opts = opts,
  }
  return setmetatable(self, { __index = _M })
end


--- 存储缓存对象
-- req_ttl 会通过 COS 对象元数据体现：设置 Cache-Control max-age 与 Expires（参见 PUT Object 请求头）
-- 注意：COS 不会在 TTL 后自动删除对象，仅作为元数据供 GET 时返回，本插件在 fetch 时仍按 req_obj.ttl 做逻辑过期判断
function _M:store(key, req_obj, req_ttl)
  if type(key) ~= "string" then
    return nil, "key must be a string"
  end
  local req_json = cjson.encode(req_obj)
  if not req_json then
    return nil, "could not encode request object"
  end
  local extra_headers = {
    ["Content-Type"] = "application/json",
    ["Content-Length"] = tostring(#req_json),
  }
  -- 腾讯云 COS PUT Object 支持 Cache-Control / Expires 请求头，将作为对象元数据保存（见 https://cloud.tencent.com/document/product/436/7749）
  local ttl = req_ttl or (req_obj and req_obj.ttl) or 0
  if ttl and ttl > 0 then
    extra_headers["Cache-Control"] = "max-age=" .. tostring(ttl)
    extra_headers["Expires"] = ngx.http_time(time() + ttl)
  end
  local object_key = cache_key_to_object_key(key)
  local res, err = cos_request(self, "PUT", object_key, {
    body = req_json,
    extra_headers = extra_headers,
  })
  if err then
    return nil, err
  end
  if res.status >= 300 then
    return nil, "COS PUT failed: " .. tostring(res.status) .. " " .. tostring(res.body and res.body:sub(1, 200))
  end
  return true, req_json
end


--- 获取缓存对象
function _M:fetch(key)
  if type(key) ~= "string" then
    return nil, "key must be a string"
  end
  local object_key = cache_key_to_object_key(key)
  local res, err = cos_request(self, "GET", object_key)
  if err then
    return nil, err
  end
  if res.status == 404 or res.status == 416 then
    return nil, "request object not in cache"
  end
  if res.status >= 300 then
    return nil, "COS GET failed: " .. tostring(res.status) .. " " .. tostring(res.body and res.body:sub(1, 200))
  end
  local body = res.body
  if not body or body == "" then
    return nil, "request object not in cache"
  end
  local req_obj = cjson.decode(body)
  if not req_obj then
    return nil, "could not decode request object"
  end
  local ttl = req_obj.ttl or 0
  if ttl > 0 and (time() - (req_obj.timestamp or 0)) > ttl then
    self:purge(key)
    return nil, "request object not in cache"
  end
  return req_obj
end


--- 删除单个缓存对象
function _M:purge(key)
  if type(key) ~= "string" then
    return nil, "key must be a string"
  end
  local object_key = cache_key_to_object_key(key)
  local res, err = cos_request(self, "DELETE", object_key)
  if err then
    return nil, err
  end
  if res.status == 204 or res.status == 200 or res.status == 404 then
    return true
  end
  return nil, "COS DELETE failed: " .. tostring(res.status) .. " " .. tostring(res.body and res.body:sub(1, 200))
end


--- 刷新 TTL（读后重写）
function _M:touch(key, req_ttl, timestamp)
  if type(key) ~= "string" then
    return nil, "key must be a string"
  end
  local req_obj, err = self:fetch(key)
  if not req_obj then
    return nil, err or "request object not in cache"
  end
  req_obj.timestamp = timestamp or time()
  return self:store(key, req_obj, req_ttl)
end


--- 清空该插件使用的对象（按前缀列举后批量删除）
function _M:flush(free_mem)
  local prefix = (self.opts.key_prefix or "proxy-cache-advanced/"):gsub("^/+", ""):gsub("/+$", "")
  if prefix ~= "" then
    prefix = prefix .. "/"
  end
  local bucket = self.opts.bucket
  local region = self.opts.region or "ap-guangzhou"
  local host = self.opts.endpoint or format("%s.cos.%s.myqcloud.com", bucket, region)
  local list_prefix = prefix
  local max_keys = 1000
  local key_start = time()
  local key_end = key_start + SIGN_EXPIRE
  local list_params = {
    listType = "2",
    prefix = list_prefix,
    ["max-keys"] = tostring(max_keys),
  }
  local list_pathname = "/"
  local list_headers = { host = host, date = ngx.http_time(ngx.time()) }
  local auth = build_cos_authorization(
    self.opts.secret_id,
    self.opts.secret_key,
    "get",
    list_pathname,
    host,
    list_headers,
    list_params,
    key_start,
    key_end
  )
  if not auth then
    return nil, auth
  end
  local timeout_ms = (self.opts.timeout or DEFAULT_TIMEOUT) * 1000
  local httpc = http:new()
  httpc:set_timeout(timeout_ms)
  local scheme = self.opts.scheme or "https"
  local ssl_verify = self.opts.ssl_verify
  if ssl_verify == nil then ssl_verify = true end
  local list_url = scheme .. "://" .. host .. "/?listType=2&prefix=" .. cos_url_encode(list_prefix) .. "&max-keys=" .. max_keys
  local list_res, list_err = httpc:request_uri(list_url, {
    method = "GET",
    headers = {
      ["Host"] = host,
      ["Date"] = list_headers["date"],
      ["Authorization"] = auth,
    },
    ssl_verify = ssl_verify,
  })
  if list_err then
    return nil, "COS list failed: " .. tostring(list_err)
  end
  if not list_res or list_res.status >= 300 then
    if list_res and list_res.status == 404 then
      return true
    end
    return nil, "COS list failed: " .. tostring(list_res and list_res.status or "no response")
  end
  local body = list_res.body or ""
  local keys_to_del = {}
  for key in body:gmatch("<Key>([^<]+)</Key>") do
    keys_to_del[#keys_to_del + 1] = key
  end
  if #keys_to_del == 0 then
    return true
  end
  -- 批量删除：COS 使用 POST /?delete 且 XML body
  local delete_xml_parts = { '<?xml version="1.0" encoding="UTF-8"?><Delete>' }
  for _, k in ipairs(keys_to_del) do
    delete_xml_parts[#delete_xml_parts + 1] = "<Object><Key>" .. k:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;") .. "</Key></Object>"
  end
  delete_xml_parts[#delete_xml_parts + 1] = "</Delete>"
  local delete_body = concat(delete_xml_parts)
  local del_pathname = "/"
  local del_params = { delete = "" }
  local del_headers = { host = host, date = ngx.http_time(ngx.time()) }
  del_headers["content-type"] = "application/xml"
  del_headers["content-length"] = tostring(#delete_body)
  local del_auth = build_cos_authorization(
    self.opts.secret_id,
    self.opts.secret_key,
    "post",
    del_pathname,
    host,
    del_headers,
    del_params,
    key_start,
    key_end
  )
  if not del_auth then
    return nil, del_auth
  end
  local del_url = scheme .. "://" .. host .. "/?delete"
  local del_res, del_err = httpc:request_uri(del_url, {
    method = "POST",
    headers = {
      ["Host"] = host,
      ["Date"] = del_headers["date"],
      ["Content-Type"] = "application/xml",
      ["Content-Length"] = tostring(#delete_body),
      ["Authorization"] = del_auth,
    },
    body = delete_body,
    ssl_verify = ssl_verify,
  })
  if del_err then
    return nil, "COS batch delete failed: " .. tostring(del_err)
  end
  if del_res and (del_res.status == 200 or del_res.status == 204) then
    return true
  end
  return nil, "COS flush delete failed: " .. tostring(del_res and del_res.status or "no response")
end


return _M
