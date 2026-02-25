---
--- Created by yq
--- DateTime: 2026/2/25 23:00
---

---
--- 阿里云 OSS（Object Storage Service）存储策略
--- 使用 OSS REST API + V1 签名：PUT/GET/DELETE Object，需网络 I/O，与 Redis 一样走 queue/timer 异步 store
--- 签名说明：https://help.aliyun.com/zh/oss/developer-reference/include-signatures-in-the-authorization-header
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

local DEFAULT_TIMEOUT = 5


--- 将缓存键转为 OSS 对象键（安全字符）
local function cache_key_to_object_key(key)
  return ngx.md5(key)
end


--- HMAC-SHA1 原始字节，再 Base64（OSS V1 签名用）
local function hmac_sha1_base64(secret_key, message)
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
  return ngx.encode_base64(ffi.string(md, len))
end


--- 构建 OSS V1 签名的 CanonicalizedOSSHeaders（x-oss- 前缀头，按名字典序，key:value\n）
local function build_canonicalized_oss_headers(headers)
  local list = {}
  for k, v in pairs(headers or {}) do
    local lower = k:lower()
    if lower:sub(1, 6) == "x-oss-" then
      list[#list + 1] = { key = lower, value = tostring(v):gsub("^%s+", ""):gsub("%s+$", "") }
    end
  end
  sort(list, function(a, b) return a.key < b.key end)
  local parts = {}
  for _, h in ipairs(list) do
    parts[#parts + 1] = h.key .. ":" .. h.value
  end
  if #parts == 0 then
    return ""
  end
  return concat(parts, "\n") .. "\n"
end


--- 构建 OSS V1 签名的 CanonicalizedResource（/BucketName/ObjectName 或 /BucketName/?subresources）
local function build_canonicalized_resource(bucket, object_key, sub_params)
  if not object_key or object_key == "" then
    if sub_params and next(sub_params) then
      local keys = {}
      for k in pairs(sub_params) do
        keys[#keys + 1] = k
      end
      sort(keys)
      local parts = {}
      for _, k in ipairs(keys) do
        parts[#parts + 1] = k .. "=" .. tostring(sub_params[k] or "")
      end
      return "/" .. bucket .. "/?" .. concat(parts, "&")
    end
    return "/" .. bucket .. "/"
  end
  if sub_params and next(sub_params) then
    local keys = {}
    for k in pairs(sub_params) do
      keys[#keys + 1] = k
    end
    sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = k .. "=" .. tostring(sub_params[k] or "")
    end
    return "/" .. bucket .. "/" .. object_key .. "?" .. concat(parts, "&")
  end
  return "/" .. bucket .. "/" .. object_key
end


--- 生成 OSS V1 Authorization 头
-- StringToSign = VERB + "\n" + Content-MD5 + "\n" + Content-Type + "\n" + Date + "\n" + CanonicalizedOSSHeaders + CanonicalizedResource
local function build_oss_authorization_v1(access_key_id, access_key_secret, method, content_md5, content_type, date_str, canonical_oss_headers, canonical_resource)
  local content_md5_s = content_md5 or ""
  local content_type_s = content_type or ""
  local string_to_sign = method .. "\n" .. content_md5_s .. "\n" .. content_type_s .. "\n" .. date_str .. "\n" .. canonical_oss_headers .. canonical_resource
  local sig, err = hmac_sha1_base64(access_key_secret, string_to_sign)
  if not sig then
    return nil, err
  end
  return "OSS " .. access_key_id .. ":" .. sig
end


--- 发起 OSS HTTP 请求（V1 签名）
local function oss_request(self, method, object_key, opts)
  opts = opts or {}
  local bucket = self.opts.bucket
  local endpoint = self.opts.endpoint or (bucket .. ".oss-cn-hangzhou.aliyuncs.com")
  local prefix = (self.opts.key_prefix or "proxy-cache-advanced/"):gsub("^/+", ""):gsub("/+$", "")
  if prefix ~= "" then
    prefix = prefix .. "/"
  end
  local path_key = (object_key and (prefix .. object_key)) or ""
  local path_enc
  if path_key == "" then
    path_enc = "/"
  else
    path_enc = "/" .. gsub(path_key, "([^/A-Za-z0-9_.%-~])", function(c)
      return format("%%%02X", c:byte(1))
    end)
  end

  local date_str = opts.date or ngx.http_time(ngx.time())
  local extra_headers = opts.extra_headers or {}
  local sub_params = opts.sub_params or {}

  local canonical_resource = build_canonicalized_resource(bucket, (object_key and (prefix .. object_key)) or nil, next(sub_params) and sub_params or nil)
  local canonical_oss = build_canonicalized_oss_headers(extra_headers)
  local content_md5 = extra_headers["Content-MD5"]
  local content_type = extra_headers["Content-Type"]

  local auth, err = build_oss_authorization_v1(
    self.opts.access_key_id,
    self.opts.access_key_secret,
    method,
    content_md5,
    content_type,
    date_str,
    canonical_oss,
    canonical_resource
  )
  if not auth then
    return nil, err
  end

  local scheme = self.opts.scheme or "https"
  local url = scheme .. "://" .. endpoint .. path_enc
  if next(sub_params) then
    local q = {}
    for k, v in pairs(sub_params) do
      q[#q + 1] = k .. "=" .. ngx.escape_uri(tostring(v))
    end
    sort(q)
    url = url .. "?" .. concat(q, "&")
  end

  local req_headers = {
    ["Host"] = endpoint,
    ["Date"] = date_str,
    ["Authorization"] = auth,
  }
  for k, v in pairs(extra_headers) do
    req_headers[k] = v
  end

  local ssl_verify = self.opts.ssl_verify
  if ssl_verify == nil then ssl_verify = true end
  local timeout_ms = (self.opts.timeout or DEFAULT_TIMEOUT) * 1000
  local httpc = http:new()
  httpc:set_timeout(timeout_ms)

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
    return nil, "OSS request failed: " .. tostring(err)
  end
  if not res then
    return nil, "OSS request returned no response"
  end
  return res, nil
end


--- 创建 OSS 策略实例
-- @table opts access_key_id, access_key_secret, bucket[, endpoint/region, key_prefix, timeout, scheme, ssl_verify]
function _M.new(opts)
  if not opts then
    return nil, "oss options are required"
  end
  if not opts.access_key_id or opts.access_key_id == "" then
    return nil, "oss.access_key_id is required"
  end
  if not opts.access_key_secret or opts.access_key_secret == "" then
    return nil, "oss.access_key_secret is required"
  end
  if not opts.bucket or opts.bucket == "" then
    return nil, "oss.bucket is required"
  end
  if not opts.endpoint and opts.region then
    opts.endpoint = opts.bucket .. "." .. opts.region .. ".aliyuncs.com"
  end
  if not opts.endpoint then
    opts.endpoint = opts.bucket .. ".oss-cn-hangzhou.aliyuncs.com"
  end
  local self = { opts = opts }
  return setmetatable(self, { __index = _M })
end


--- 存储缓存对象
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
  local ttl = req_ttl or (req_obj and req_obj.ttl) or 0
  if ttl and ttl > 0 then
    extra_headers["Cache-Control"] = "max-age=" .. tostring(ttl)
    extra_headers["Expires"] = ngx.http_time(time() + ttl)
  end
  local object_key = cache_key_to_object_key(key)
  local prefix = (self.opts.key_prefix or "proxy-cache-advanced/"):gsub("^/+", ""):gsub("/+$", "")
  if prefix ~= "" then prefix = prefix .. "/" end
  local full_key = prefix .. object_key
  local res, err = oss_request(self, "PUT", object_key, {
    body = req_json,
    extra_headers = extra_headers,
  })
  if err then
    return nil, err
  end
  if res.status >= 300 then
    return nil, "OSS PUT failed: " .. tostring(res.status) .. " " .. tostring(res.body and res.body:sub(1, 200))
  end
  return true, req_json
end


--- 获取缓存对象
function _M:fetch(key)
  if type(key) ~= "string" then
    return nil, "key must be a string"
  end
  local object_key = cache_key_to_object_key(key)
  local res, err = oss_request(self, "GET", object_key)
  if err then
    return nil, err
  end
  if res.status == 404 then
    return nil, "request object not in cache"
  end
  if res.status >= 300 then
    return nil, "OSS GET failed: " .. tostring(res.status) .. " " .. tostring(res.body and res.body:sub(1, 200))
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
  local res, err = oss_request(self, "DELETE", object_key)
  if err then
    return nil, err
  end
  if res.status == 204 or res.status == 200 or res.status == 404 then
    return true
  end
  return nil, "OSS DELETE failed: " .. tostring(res.status) .. " " .. tostring(res.body and res.body:sub(1, 200))
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
  local list_res, list_err = oss_request(self, "GET", nil, {
    sub_params = { ["max-keys"] = "1000", prefix = prefix },
  })
  if list_err then
    return nil, "OSS list failed: " .. tostring(list_err)
  end
  if not list_res or list_res.status >= 300 then
    if list_res and list_res.status == 404 then
      return true
    end
    return nil, "OSS list failed: " .. tostring(list_res and list_res.status or "no response")
  end
  local body = list_res.body or ""
  local keys_to_del = {}
  for key in body:gmatch("<Key>([^<]+)</Key>") do
    keys_to_del[#keys_to_del + 1] = key
  end
  if #keys_to_del == 0 then
    return true
  end
  local delete_xml_parts = { '<?xml version="1.0" encoding="UTF-8"?><Delete>' }
  for _, k in ipairs(keys_to_del) do
    delete_xml_parts[#delete_xml_parts + 1] = "<Object><Key>" .. k:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;") .. "</Key></Object>"
  end
  delete_xml_parts[#delete_xml_parts + 1] = "</Delete>"
  local delete_body = concat(delete_xml_parts)
  local content_md5 = ngx.encode_base64(ngx.md5_bin(delete_body))
  local extra_headers = {
    ["Content-Type"] = "application/xml",
    ["Content-Length"] = tostring(#delete_body),
    ["Content-MD5"] = content_md5,
  }
  local date_str = ngx.http_time(ngx.time())
  local canonical_oss = build_canonicalized_oss_headers(extra_headers)
  local canonical_resource = build_canonicalized_resource(bucket, nil, { delete = "" })
  local auth, auth_err = build_oss_authorization_v1(
    self.opts.access_key_id,
    self.opts.access_key_secret,
    "POST",
    content_md5,
    "application/xml",
    date_str,
    canonical_oss,
    canonical_resource
  )
  if not auth then
    return nil, auth_err
  end
  local endpoint = self.opts.endpoint or (bucket .. ".oss-cn-hangzhou.aliyuncs.com")
  local scheme = self.opts.scheme or "https"
  local timeout_ms = (self.opts.timeout or DEFAULT_TIMEOUT) * 1000
  local httpc = http:new()
  httpc:set_timeout(timeout_ms)
  local ssl_verify = self.opts.ssl_verify
  if ssl_verify == nil then ssl_verify = true end
  local del_res, del_err = httpc:request_uri(scheme .. "://" .. endpoint .. "/?delete", {
    method = "POST",
    headers = {
      ["Host"] = endpoint,
      ["Date"] = date_str,
      ["Content-Type"] = "application/xml",
      ["Content-Length"] = tostring(#delete_body),
      ["Content-MD5"] = content_md5,
      ["Authorization"] = auth,
    },
    body = delete_body,
    ssl_verify = ssl_verify,
  })
  if del_err then
    return nil, "OSS batch delete failed: " .. tostring(del_err)
  end
  if del_res and (del_res.status == 200 or del_res.status == 204) then
    return true
  end
  return nil, "OSS flush delete failed: " .. tostring(del_res and del_res.status or "no response")
end


return _M
